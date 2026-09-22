#!/bin/bash
set -e

INSTALLER="${1:-$HOME/Downloads/apply_openmw_tsp_manager_v46_calibrator_FIXED-21.sh}"
BACKUP="${INSTALLER}.before-v47.$(date +%Y%m%d-%H%M%S)"

[ -f "$INSTALLER" ] || {
    echo "ERROR: installer not found: $INSTALLER"
    exit 1
}

cp -p "$INSTALLER" "$BACKUP"
echo "Backup: $BACKUP"

python3 - "$INSTALLER" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

# Require the exact V46 base this patch was built against.
if '// TSP_MANAGER_V46_CALIBRATOR_UI' not in s:
    raise SystemExit('ERROR: V46 calibration source marker not found')
if 'muosControllerDeviceCount()' not in s or 'muosInputdCount()' not in s:
    raise SystemExit('ERROR: V46 duplicate-safe controller restoration is missing')
if 'root@192.168.1.21' not in s:
    raise SystemExit('ERROR: installer does not target root@192.168.1.21')

# Let the manager explicitly release UARTs before restoring the stock daemon.
old_reader = '''    ~TspUartReader(){if(mFd>=0)close(mFd);}
    bool openPort()
'''
new_reader = '''    ~TspUartReader(){closePort();}
    void closePort(){if(mFd>=0){close(mFd);mFd=-1;}}
    bool openPort()
'''
if s.count(old_reader) != 1:
    raise SystemExit(f'ERROR: expected one TspUartReader destructor block, found {s.count(old_reader)}')
s = s.replace(old_reader, new_reader, 1)

# The unified workflow no longer reloads a center profile between stages, so
# remove the old helper instead of leaving an unused static function under -Werror.
load_start = s.find('static bool loadCalibrationProfile(const fs::path&file,CalStick&left,CalStick&right)')
load_end = s.find('static bool writeCalibrationProfile(', load_start)
if load_start < 0 or load_end < 0:
    raise SystemExit('ERROR: could not locate old calibration-profile loader')
s = s[:load_start] + s[load_end:]

# Mark only a COMPLETE center+range profile as saved. The launcher ignores this
# extra INI key; it still consumes the same center/scale keys as before.
old_writer = '''    o<<"right_y_center="<<right.y.center<<"\\n";
    o<<"left_x_scale="<<sx(left.x)<<"\\n";
'''
new_writer = '''    o<<"right_y_center="<<right.y.center<<"\\n";
    o<<"range_calibrated="<<(recomputeRange?"1":"0")<<"\\n";
    o<<"left_x_scale="<<sx(left.x)<<"\\n";
'''
if s.count(old_writer) != 1:
    raise SystemExit(f'ERROR: expected one calibration profile writer anchor, found {s.count(old_writer)}')
s = s.replace(old_writer, new_writer, 1)

# Replace only the V46 calibrator implementation. The daemon/uinput restoration
# functions immediately above it are deliberately left untouched.
start = s.find('// TSP_MANAGER_V46_CALIBRATOR_UI')
end = s.find('static void homePage(Framebuffer&f,App&a)', start)
if start < 0 or end < 0:
    raise SystemExit('ERROR: could not locate V46 calibration implementation')

new_block = r'''// TSP_MANAGER_V47_CALIBRATOR_UI
// One A press performs the complete calibration in a single UART session:
// center -> 5s left outer circle -> 5s right outer circle -> atomic save.
// Center values remain in memory and feed the range measurement directly.

static void stickCircle(Framebuffer&f,int cx,int cy,int r,int x,int y,
                        bool active,const std::string&name)
{
    label(f,name,cx-76,cy-r-34,2,FG);
    for(int d=0;d<360;d+=2)
    {
        double rad=double(d)*3.14159265358979323846/180.0;
        int px=cx+int(std::cos(rad)*r),py=cy+int(std::sin(rad)*r);
        f.pixel(px,py,active?ACC:DIM);
    }
    f.rect(cx-r,cy,r*2+1,1,DIM);
    f.rect(cx,cy-r,1,r*2+1,DIM);
    int px=cx+clampInt(x,-1200,1200)*r/1200;
    int py=cy+clampInt(y,-1200,1200)*r/1200;
    f.rect(px-5,py-5,11,11,active?ACC:WARN);
}

static bool completeCalibrationProfile(const fs::path&profile)
{
    auto k=readKv(profile);
    auto i=k.find("range_calibrated");
    return i!=k.end()&&i->second=="1";
}

static void calibrationPreviewScreen(Framebuffer&f,const Inputs&in,const fs::path&profile)
{
    int lx=0,ly=0,rx=0,ry=0;
    in.stickAxes(lx,ly,rx,ry);
    int lxp=clampInt(lx*1200/32760,-1200,1200);
    int lyp=clampInt(ly*1200/32760,-1200,1200);
    int rxp=clampInt(rx*1200/32760,-1200,1200);
    int ryp=clampInt(ry*1200/32760,-1200,1200);

    f.paper();header(f);title(f,"STICK CALIBRATOR","LIVE INPUT / CALIBRATION");
    f.rect(350,170,902,475,P1);
    stickCircle(f,570,325,102,lxp,lyp,true,"LEFT STICK");
    stickCircle(f,935,325,102,rxp,ryp,true,"RIGHT STICK");

    // Each output sits beneath its own stick visualization.
    label(f,"LEFT OUTPUT",455,465,1,DIM);
    label(f,std::to_string(lx)+" / "+std::to_string(ly),555,465,1,FG);
    label(f,"RIGHT OUTPUT",820,465,1,DIM);
    label(f,std::to_string(rx)+" / "+std::to_string(ry),930,465,1,FG);

    // Status belongs in the upper-right corner of the menu box.
    const bool saved=completeCalibrationProfile(profile);
    label(f,saved?"PROFILE SAVED":"PROFILE NOT SAVED",1040,195,1,saved?GOOD:WARN);

    label(f,"A  CALIBRATE CENTER + FULL RANGE",430,535,2,ACC);
    label(f,"B  BACK",430,565,2,DIM);
    label(f,"A samples center, then runs a 5-second circular outer sweep on each stick.",430,605,1,DIM);
    label(f,"Keep the active stick against the outer edge while circling. B cancels.",430,629,1,DIM);
    f.present();
}

static void calibrationStageScreen(Framebuffer&f,const std::string&phase,
                                   const std::string&detail,
                                   const CalStick&left,const CalStick&right,
                                   int stage)
{
    f.paper();header(f);title(f,"STICK CALIBRATOR",phase);
    f.rect(350,170,902,475,P1);

    // Before center is known, keep the visual markers centered. Raw values are
    // still printed below. Range stages use the freshly measured center.
    int lx=0,ly=0,rx=0,ry=0;
    if(stage!=1)
    {
        lx=left.lastX-left.x.center;
        ly=left.lastY-left.y.center;
        rx=right.lastX-right.x.center;
        ry=right.lastY-right.y.center;
    }

    stickCircle(f,570,325,102,lx,ly,true,"LEFT STICK");
    stickCircle(f,935,325,102,rx,ry,true,"RIGHT STICK");

    label(f,"LEFT OUTPUT",455,465,1,DIM);
    label(f,std::to_string(left.lastX)+" / "+std::to_string(left.lastY),555,465,1,FG);
    label(f,"RIGHT OUTPUT",820,465,1,DIM);
    label(f,std::to_string(right.lastX)+" / "+std::to_string(right.lastY),930,465,1,FG);

    if(stage==1)
    {
        label(f,"CENTER SAMPLES",930,195,1,DIM);
        label(f,std::to_string(left.packets)+" / 50",1060,195,1,FG);
    }
    else
    {
        const CalStick&st=(stage==2)?left:right;
        const int travel=std::min(std::min(std::max(0,st.x.negTravel()),std::max(0,st.x.posTravel())),
                                  std::min(std::max(0,st.y.negTravel()),std::max(0,st.y.posTravel())));
        const int pct=clampInt(travel*100/600,0,100);
        label(f,"RANGE",1020,195,1,DIM);
        label(f,std::to_string(pct)+"%",1090,195,1,FG);
    }

    auto lines=wrapText(detail,92,3);
    for(size_t i=0;i<lines.size();++i)
        label(f,lines[i],430,585+int(i)*24,1,FG);
    f.present();
}

static bool runMuosCalibration(App&a,Framebuffer&f,Inputs&in)
{
    if(!tspMuosPresent())
    {
        a.lastResult="STICK CALIBRATION IS AVAILABLE ON MUOS ONLY";
        return false;
    }

    const fs::path profile=a.root/"tsp_muos_stick_calibration.ini";

    // Keep the working V46 duplicate-input fix: stop the stock producer once,
    // perform every calibration stage, then restore exactly one stock daemon
    // and one uinput controller only after both UART descriptors are closed.
    stopMuosInputd();

    TspUartReader leftReader("/dev/ttyS4"),rightReader("/dev/ttyS3");
    if(!leftReader.openPort()||!rightReader.openPort())
    {
        a.lastResult="Could not open or configure muOS controller UARTs /dev/ttyS4 and /dev/ttyS3";
        leftReader.closePort();rightReader.closePort();
        restoreMuosInputd();usleep(250000);in.reopen();return false;
    }

    CalStick left,right;
    bool cancel=false;

    // CENTER: restore the shorter, previously useful behavior. Fifty packets
    // per UART is enough for a stable neutral average and avoids V46's doubled
    // 80-sample / 8-second feel.
    const auto centerStart=std::chrono::steady_clock::now();
    int lc=0,rc=0;
    long long lsx=0,lsy=0,rsx=0,rsy=0;

    while(lc<50||rc<50)
    {
        pollfd p[2]={
            {leftReader.fd(),POLLIN,0},
            {rightReader.fd(),POLLIN,0}
        };
        ::poll(p,2,30);
        CalSample sm;

        while(leftReader.packet(sm))
        {
            left.lastX=sm.x;left.lastY=sm.y;left.buttons=sm.buttons;
            if(lc<50){lsx+=sm.x;lsy+=sm.y;++lc;}
        }
        while(rightReader.packet(sm))
        {
            right.lastX=sm.x;right.lastY=sm.y;right.buttons=sm.buttons;
            if(rc<50){rsx+=sm.x;rsy+=sm.y;++rc;}
            if(sm.buttons&0x20)cancel=true; // physical B lives on right UART
        }

        left.packets=lc;right.packets=rc;
        calibrationStageScreen(f,"CENTER CALIBRATION",
            "Keep both sticks released and centered while the neutral position is sampled. B cancels.",
            left,right,1);

        if(cancel)break;
        if(std::chrono::steady_clock::now()-centerStart>std::chrono::seconds(4))break;
    }

    if(cancel||lc<20||rc<20)
    {
        a.lastResult=cancel
            ?"Calibration cancelled; no settings were changed"
            :"Center calibration did not receive enough samples";
        leftReader.closePort();rightReader.closePort();
        restoreMuosInputd();usleep(250000);in.reopen();return false;
    }

    // This center is passed DIRECTLY to the range stages below. Nothing is
    // saved/reloaded and the daemon is not restarted in between.
    left.x.center=int(lsx/lc);left.y.center=int(lsy/lc);
    right.x.center=int(rsx/rc);right.y.center=int(rsy/rc);
    left.x.minv=left.x.maxv=left.x.center;
    left.y.minv=left.y.maxv=left.y.center;
    right.x.minv=right.x.maxv=right.x.center;
    right.y.minv=right.y.maxv=right.y.center;
    left.packets=right.packets=0;

    auto sweep=[&](bool watchLeft,int stage)->bool
    {
        const auto begun=std::chrono::steady_clock::now();
        const auto finish=begun+std::chrono::seconds(5);

        while(std::chrono::steady_clock::now()<finish)
        {
            pollfd p[2]={
                {leftReader.fd(),POLLIN,0},
                {rightReader.fd(),POLLIN,0}
            };
            ::poll(p,2,25);
            CalSample sm;

            while(leftReader.packet(sm))
            {
                left.lastX=sm.x;left.lastY=sm.y;left.buttons=sm.buttons;
                if(watchLeft){left.x.observe(sm.x);left.y.observe(sm.y);++left.packets;}
            }
            while(rightReader.packet(sm))
            {
                right.lastX=sm.x;right.lastY=sm.y;right.buttons=sm.buttons;
                if(!watchLeft){right.x.observe(sm.x);right.y.observe(sm.y);++right.packets;}
                if(sm.buttons&0x20)cancel=true;
            }

            const auto now=std::chrono::steady_clock::now();
            long long remain=std::chrono::duration_cast<std::chrono::milliseconds>(finish-now).count();
            if(remain<0)remain=0;

            std::ostringstream d;
            if(watchLeft)d<<"Move the LEFT stick in a circle around the outer edge for 5 seconds. ";
            else d<<"Now move the RIGHT stick in a circle around the outer edge for 5 seconds. ";
            d<<"Time remaining: "<<(remain/1000)<<"."<<((remain%1000)/100)<<"s. B cancels.";

            calibrationStageScreen(f,
                watchLeft?"LEFT STICK RANGE":"RIGHT STICK RANGE",
                d.str(),left,right,stage);
            if(cancel)return false;
        }
        return true;
    };

    if(!sweep(true,2))
    {
        a.lastResult="Calibration cancelled; no settings were changed";
        leftReader.closePort();rightReader.closePort();
        restoreMuosInputd();usleep(250000);in.reopen();return false;
    }

    calibrationStageScreen(f,"SWITCH TO RIGHT STICK",
        "LEFT stick captured. Now use the RIGHT stick and keep it against the outer edge while circling.",
        left,right,3);
    usleep(350000);

    cancel=false;
    if(!sweep(false,3))
    {
        a.lastResult="Calibration cancelled; no settings were changed";
        leftReader.closePort();rightReader.closePort();
        restoreMuosInputd();usleep(250000);in.reopen();return false;
    }

    // Reject an incomplete circle. 600 raw counts is comfortably below the
    // ~900+ normal physical travel but high enough to catch a missed side.
    const int target=600;
    const bool leftComplete=
        left.x.negTravel()>=target&&left.x.posTravel()>=target&&
        left.y.negTravel()>=target&&left.y.posTravel()>=target;
    const bool rightComplete=
        right.x.negTravel()>=target&&right.x.posTravel()>=target&&
        right.y.negTravel()>=target&&right.y.posTravel()>=target;

    if(!leftComplete||!rightComplete)
    {
        a.lastResult="Outer-range sweep did not reach all four directions on both sticks; profile was not changed";
        leftReader.closePort();rightReader.closePort();
        restoreMuosInputd();usleep(250000);in.reopen();return false;
    }

    // calibratedScale() uses the shorter positive/negative travel on each axis,
    // so both directions remain balanced even when the hardware extrema differ.
    const bool ok=writeCalibrationProfile(profile,left,right,true);
    a.lastResult=ok
        ?"Calibration saved: center + balanced full-range travel"
        :"Could not save the stick calibration profile";

    leftReader.closePort();rightReader.closePort();
    restoreMuosInputd();usleep(250000);in.reopen();
    return ok;
}

'''

s = s[:start] + new_block + s[end:]

# A is the only calibration action now. X returns to being just the manager's
# normal Refresh action outside this page.
old_handle = 'else if(a.page==Page::Calibrate){if(q==Action::Back)a.page=Page::Home;else if(q==Action::Select)a.calibrationMode=1;else if(q==Action::Refresh)a.calibrationMode=2;}'
new_handle = 'else if(a.page==Page::Calibrate){if(q==Action::Back)a.page=Page::Home;else if(q==Action::Select)a.calibrationMode=1;}'
if s.count(old_handle) != 1:
    raise SystemExit(f'ERROR: expected one V46 calibration handler, found {s.count(old_handle)}')
s = s.replace(old_handle,new_handle,1)

old_dispatch = '''            if(a.calibrationMode)
            {
                const int mode=a.calibrationMode;a.calibrationMode=0;
                if(mode==1)runMuosCenterCalibration(a,fb,in);
                else runMuosRangeCalibration(a,fb,in);
                dirty=true;
                last=std::chrono::steady_clock::now();
            }
'''
new_dispatch = '''            if(a.calibrationMode)
            {
                a.calibrationMode=0;
                runMuosCalibration(a,fb,in);
                dirty=true;
                last=std::chrono::steady_clock::now();
            }
'''
if s.count(old_dispatch) != 1:
    raise SystemExit(f'ERROR: expected one V46 calibration dispatch, found {s.count(old_dispatch)}')
s = s.replace(old_dispatch,new_dispatch,1)

# Replace the V46 calibration-specific self-test assertions while preserving all
# unrelated manager, mod, storage, launcher and platform tests.
assert_start = s.find('    grep -Fq \'TSP_MANAGER_V46_CALIBRATOR_UI\' "$CPP" || fail 16 "V46 calibrator marker missing"')
assert_end = s.find('    grep -Fq \'case BTN_NORTH: return Action::Mark;\' "$CPP" || fail 16 "Y no longer picks a mod up"', assert_start)
if assert_start < 0 or assert_end < 0:
    raise SystemExit('ERROR: could not locate V46 calibration self-test assertions')

new_asserts = r'''    grep -Fq 'TSP_MANAGER_V47_CALIBRATOR_UI' "$CPP" || fail 16 "V47 calibrator marker missing"
    grep -Fq '/dev/ttyS4' "$CPP" || fail 16 "left calibration UART missing"
    grep -Fq '/dev/ttyS3' "$CPP" || fail 16 "right calibration UART missing"
    grep -Fq 'A  CALIBRATE CENTER + FULL RANGE' "$CPP" || fail 16 "combined calibration control missing"
    grep -Fq 'Move the LEFT stick in a circle around the outer edge for 5 seconds.' "$CPP" || fail 16 "left circular range sweep missing"
    grep -Fq 'Now move the RIGHT stick in a circle around the outer edge for 5 seconds.' "$CPP" || fail 16 "right circular range sweep missing"
    grep -Fq 'const auto finish=begun+std::chrono::seconds(5)' "$CPP" || fail 16 "range sweep is not five seconds"
    grep -Fq 'while(lc<50||rc<50)' "$CPP" || fail 16 "short center calibration is missing"
    grep -Fq 'left.x.center=int(lsx/lc)' "$CPP" || fail 16 "center result is not fed into range calibration"
    grep -Fq 'writeCalibrationProfile(profile,left,right,true)' "$CPP" || fail 16 "complete profile save missing"
    grep -Fq 'range_calibrated=' "$CPP" || fail 16 "complete-profile flag missing"
    grep -Fq 'completeCalibrationProfile(profile)' "$CPP" || fail 16 "profile status is not tied to complete calibration"
    grep -Fq 'label(f,"LEFT OUTPUT",455,465' "$CPP" || fail 16 "left output is not beneath left stick"
    grep -Fq 'label(f,"RIGHT OUTPUT",820,465' "$CPP" || fail 16 "right output is not beneath right stick"
    grep -Fq 'PROFILE NOT SAVED",1040,195' "$CPP" || fail 16 "profile status is not in upper-right"
    grep -Fq 'if(q==Action::Select)a.calibrationMode=1' "$CPP" || fail 16 "A no longer starts combined calibration"
    if grep -Fq 'a.calibrationMode=2' "$CPP"; then fail 16 "separate X calibration action remains"; fi
    grep -Fq 'void closePort(){if(mFd>=0){close(mFd);mFd=-1;}}' "$CPP" || fail 16 "UART release helper missing"
    grep -Fq 'muosInputdCount()' "$CPP" || fail 16 "duplicate-safe daemon restore missing"
    grep -Fq 'muosControllerDeviceCount()' "$CPP" || fail 16 "duplicate-safe uinput restore missing"
    grep -Fq 'TSP_MANAGER_V44_FACE_BUTTONS' "$CPP" || fail 16 "face-button correction marker missing"
    grep -Fq 'Inputs in(smartProFaceSwap)' "$CPP" || fail 16 "layout-aware input construction missing"
    grep -Fq 'if(a.page==Page::Calibrate)dirty=true;' "$CPP" || fail 16 "live calibration redraw missing"
'''
s = s[:assert_start] + new_asserts + s[assert_end:]

# Update only the installer-level calibration marker/description. The universal
# multi-OS package remains otherwise unchanged.
s = s.replace('# TSP_MANAGER_V46_CALIBRATOR_UI', '# TSP_MANAGER_V47_CALIBRATOR_UI', 1)

p.write_text(s)
print('PASS: patched V46 installer to V47 combined calibration')
PY

echo
echo "===== VERIFY V47 PATCH ====="
grep -nE 'TSP_MANAGER_V47_CALIBRATOR_UI|A  CALIBRATE CENTER \+ FULL RANGE|range_calibrated=|Move the LEFT stick in a circle|Now move the RIGHT stick in a circle|root@192.168.1.21' "$INSTALLER" | head -80

echo
echo "===== RUN V47 HOST SELFTEST ====="
bash "$INSTALLER" selftest

echo
echo "=============================================="
echo "V47 PATCH COMPLETE"
echo "=============================================="
echo "Installer was patched and self-tested, but NOT installed."
echo "Installer: $INSTALLER"
echo "Backup:    $BACKUP"
echo
echo "Install with:"
echo "  bash \"$INSTALLER\""
