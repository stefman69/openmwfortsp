#!/usr/bin/env bash
set -euo pipefail

INSTALLER="$HOME/Downloads/apply_openmw_tsp_manager_v43_calibrator.sh"
LOG="$HOME/Downloads/TSP_input_investigation.txt"
BACKUP="${INSTALLER}.before-v44.$(date +%Y%m%d-%H%M%S)"

[ -f "$INSTALLER" ] || { echo "ERROR: installer not found: $INSTALLER"; exit 1; }
cp -p "$INSTALLER" "$BACKUP"
echo "Backup: $BACKUP"

python3 - <<'PY'
from pathlib import Path

p = Path.home() / 'Downloads' / 'apply_openmw_tsp_manager_v43_calibrator.sh'
s = p.read_text()

def replace_once(old,new,label):
    global s
    c=s.count(old)
    if c!=1:
        raise SystemExit(f'{label}: expected 1, found {c}')
    s=s.replace(old,new)

# Header marker.
s=s.replace('# TSP_MANAGER_V43_MUOS_CALIBRATOR', '# TSP_MANAGER_V44_CALIBRATOR_FACE_BUTTONS', 1)
s=s.replace('// TSP_MANAGER_V43_MUOS_CALIBRATOR', '// TSP_MANAGER_V44_CALIBRATOR_FACE_BUTTONS')

# Inputs constructor.
replace_once('''class Inputs
{
public:
    Inputs(){''', '''class Inputs
{
public:
    explicit Inputs(bool smartProFaceSwap=false):mSmartProFaceSwap(smartProFaceSwap){''', 'Inputs constructor')

# Face-button mapping helper before Inputs.
replace_once('''class Inputs
{
public:
''', '''static unsigned mapFaceButtonCode(unsigned code,bool smartProFaceSwap)
{
    if(!smartProFaceSwap)return code;
    if(code==BTN_SOUTH)return BTN_EAST;
    if(code==BTN_EAST)return BTN_SOUTH;
    if(code==BTN_NORTH)return BTN_WEST;
    if(code==BTN_WEST)return BTN_NORTH;
    return code;
}

class Inputs
{
public:
''', 'mapping helper')

replace_once('''            Action a=fromKey(e.code);
            // TSP_MANAGER_V40_MOD_REORDER: a real trigger button retires the axis path.
''', '''            unsigned mappedCode=mapFaceButtonCode(e.code,mSmartProFaceSwap);
            // TSP_MANAGER_V44_FACE_BUTTONS: Knulli/muOS use the Smart Pro
            // physical face-button ordering; Stock/CrossMix remains unchanged.
            Action a=fromKey(mappedCode);
            // TSP_MANAGER_V40_MOD_REORDER: a real trigger button retires the axis path.
''', 'consume mapping')

replace_once('''    std::vector<int>mFds;std::vector<pollfd>mPoll;int mHx=0,mHy=0;
    // TSP_MANAGER_V40_MOD_REORDER: learned analog trigger range and edge state.
''', '''    std::vector<int>mFds;std::vector<pollfd>mPoll;int mHx=0,mHy=0;
    bool mSmartProFaceSwap=false;
    // TSP_MANAGER_V40_MOD_REORDER: learned analog trigger range and edge state.
''', 'mapping member')

# Full-range scale: do not cap to legacy 900.
replace_once('''static int calibratedScale(int negTravel,int posTravel)
{
    int usable=std::min(std::abs(negTravel),std::abs(posTravel));
    if(usable<=0) return 900;
    // Never make the stock +/-900 path less sensitive. A unit whose physical
    // travel exceeds 900 already reaches full output with the launcher route.
    return clampInt(std::min(900,usable),100,900);
}
''', '''static int calibratedScale(int negTravel,int posTravel)
{
    int neg=std::abs(negTravel),pos=std::abs(posTravel);
    if(neg<=0||pos<=0)return 900;
    // Use the shorter measured physical travel as the full-scale point for
    // this axis. A shorter side reaches 100% at its actual mechanical limit;
    // a longer side is simply clamped there. This makes the range calibration
    // materially affect the launcher instead of being a center-only exercise.
    return clampInt(std::min(neg,pos),100,5000);
}
''', 'calibrated scale')

# Replace visual helper and calibration routine through homePage.
start=s.index('static void stickCircle(')
end=s.index('static void homePage(',start)
new_block=r'''static void stickCircle(Framebuffer&f,int cx,int cy,int r,int x,int y,
                        bool active,const std::string&name,
                        bool leftDone,bool rightDone,bool upDone,bool downDone)
{
    label(f,name,cx-76,cy-r-34,2,FG);
    for(int d=0;d<360;d+=2)
    {
        double rad=double(d)*3.14159265358979323846/180.0;
        int px=cx+int(std::cos(rad)*r),py=cy+int(std::sin(rad)*r);
        f.pixel(px,py,active?ACC:DIM);
    }
    f.rect(cx-r,cy,r*2+1,1,DIM);f.rect(cx,cy-r,1,r*2+1,DIM);
    int px=cx+clampInt(x,-1200,1200)*r/1200;
    int py=cy+clampInt(y,-1200,1200)*r/1200;
    f.rect(px-5,py-5,11,11,active?ACC:WARN);
    auto check=[&](const char*txt,int tx,int ty,bool ok){label(f,ok?"[x]":"[ ]",tx,ty,1,ok?GOOD:DIM);label(f,txt,tx+28,ty,1,DIM);};
    check("LEFT",cx-r-8,cy+r+32,leftDone);
    check("RIGHT",cx+r-36,cy+r+32,rightDone);
    check("UP",cx-r-8,cy+r+52,upDone);
    check("DOWN",cx+r-36,cy+r+52,downDone);
}

static void calibrationScreen(Framebuffer&f,const std::string&phase,const std::string&detail,
                              const CalStick*left=nullptr,const CalStick*right=nullptr,
                              int stage=0)
{
    f.paper();header(f);title(f,"STICK CALIBRATOR",phase);
    f.rect(350,175,902,420,P1);
    if(left&&right)
    {
        // Display uses output-style orientation: X inverted, Y inverted.
        int lx=-left->x.center+left->lastX,ly=-left->y.center+left->lastY;
        int rx=-right->x.center+right->lastX,ry=-right->y.center+right->lastY;
        bool lleft=left->x.posTravel()>=80;
        bool lright=left->x.negTravel()>=80;
        bool lup=left->y.posTravel()>=80;
        bool ldown=left->y.negTravel()>=80;
        bool rleft=right->x.posTravel()>=80;
        bool rright=right->x.negTravel()>=80;
        bool rup=right->y.posTravel()>=80;
        bool rdown=right->y.negTravel()>=80;
        stickCircle(f,570,335,102,lx,ly,true,"LEFT STICK",lleft,lright,lup,ldown);
        stickCircle(f,935,335,102,rx,ry,true,"RIGHT STICK",rleft,rright,rup,rdown);
        row(f,410,475,"LEFT X/Y",std::to_string(left->lastX)+" / "+std::to_string(left->lastY),FG);
        row(f,410,501,"RIGHT X/Y",std::to_string(right->lastX)+" / "+std::to_string(right->lastY),FG);
        if(stage==1)
        {
            label(f,"CENTER SAMPLES",800,475,1,DIM);
            label(f,std::to_string(left->packets)+" / 80",930,475,1,FG);
        }
    }
    auto lines=wrapText(detail,92,3);
    for(size_t i=0;i<lines.size();++i)label(f,lines[i],390,610+int(i)*24,1,FG);
    f.present();
}

static bool runMuosCalibration(App&a,Framebuffer&f,Inputs&in)
{
    if(!tspMuosPresent()){a.lastResult="STICK CALIBRATION IS AVAILABLE ON MUOS ONLY";return false;}
    calibrationScreen(f,"PREPARING","The stock muOS controller service will pause only while calibration runs.");
    stopMuosInputd();
    TspUartReader leftReader("/dev/ttyS4"),rightReader("/dev/ttyS3");
    if(!leftReader.openPort()||!rightReader.openPort())
    {
        if(leftReader.fd()<0||rightReader.fd()<0)a.lastResult="Could not open muOS controller UARTs /dev/ttyS4 and /dev/ttyS3";
        else a.lastResult="Could not configure the muOS controller UARTs at 19200 8N1";
        restoreMuosInputd();in.reopen();return false;
    }

    CalStick left,right;
    const auto started=std::chrono::steady_clock::now();
    int leftCenterCount=0,rightCenterCount=0;
    long long leftSumX=0,leftSumY=0,rightSumX=0,rightSumY=0;
    bool cancel=false;

    // Stage 1: stable center for both sticks. Buttons continue to be read so
    // B really is an exit control even before the center sample completes.
    while(leftCenterCount<80||rightCenterCount<80)
    {
        pollfd p[2]={{leftReader.fd(),POLLIN,0},{rightReader.fd(),POLLIN,0}};
        ::poll(p,2,30);
        CalSample sm;
        while(leftReader.packet(sm))
        {
            left.lastX=sm.x;left.lastY=sm.y;left.buttons=sm.buttons;
            if(leftCenterCount<80){leftSumX+=sm.x;leftSumY+=sm.y;++leftCenterCount;}
            if(sm.buttons&0x20)cancel=true;
        }
        while(rightReader.packet(sm))
        {
            right.lastX=sm.x;right.lastY=sm.y;right.buttons=sm.buttons;
            if(rightCenterCount<80){rightSumX+=sm.x;rightSumY+=sm.y;++rightCenterCount;}
            if(sm.buttons&0x20)cancel=true;
        }
        left.packets=leftCenterCount;right.packets=rightCenterCount;
        calibrationScreen(f,"CENTERING","Release both sticks completely. Keep them centered while the manager samples the neutral position. B exits without saving.",&left,&right,1);
        if(cancel)break;
        if(std::chrono::steady_clock::now()-started>std::chrono::seconds(6))break;
    }
    if(cancel)
    {
        a.lastResult="Calibration cancelled; no settings were changed";
        restoreMuosInputd();in.reopen();return false;
    }
    if(leftCenterCount<20||rightCenterCount<20)
    {
        a.lastResult="Calibration could not collect enough center samples from both sticks";
        restoreMuosInputd();in.reopen();return false;
    }
    left.x.center=int(leftSumX/leftCenterCount);left.y.center=int(leftSumY/leftCenterCount);
    right.x.center=int(rightSumX/rightCenterCount);right.y.center=int(rightSumY/rightCenterCount);
    left.x.minv=left.x.maxv=left.x.center;left.y.minv=left.y.maxv=left.y.center;
    right.x.minv=right.x.maxv=right.x.center;right.y.minv=right.y.maxv=right.y.center;

    // Every range stage drains BOTH UARTs. The selected stick supplies the
    // extrema; the right UART supplies A/B because the TSP routes face buttons
    // on the right serial stream.
    auto rangeStage=[&](bool watchLeft,int stage,const std::string&detail)->bool
    {
        const auto stageStart=std::chrono::steady_clock::now();
        while(true)
        {
            pollfd p[2]={{leftReader.fd(),POLLIN,0},{rightReader.fd(),POLLIN,0}};
            ::poll(p,2,25);
            bool accept=false;
            CalSample sm;
            while(leftReader.packet(sm))
            {
                left.lastX=sm.x;left.lastY=sm.y;left.buttons=sm.buttons;
                if(watchLeft){left.x.observe(sm.x);left.y.observe(sm.y);}
                if(sm.buttons&0x20)cancel=true;
                if(sm.buttons&0x10)accept=true;
            }
            while(rightReader.packet(sm))
            {
                right.lastX=sm.x;right.lastY=sm.y;right.buttons=sm.buttons;
                if(!watchLeft){right.x.observe(sm.x);right.y.observe(sm.y);}
                // A/B are on the right UART for this controller.
                if(sm.buttons&0x20)cancel=true;
                if(sm.buttons&0x10)accept=true;
            }
            calibrationScreen(f,stage==2?"LEFT STICK RANGE":"RIGHT STICK RANGE",detail,&left,&right,stage);
            bool complete=watchLeft
                ? (left.x.negTravel()>=80&&left.x.posTravel()>=80&&left.y.negTravel()>=80&&left.y.posTravel()>=80)
                : (right.x.negTravel()>=80&&right.x.posTravel()>=80&&right.y.negTravel()>=80&&right.y.posTravel()>=80);
            if(cancel)return false;
            if(accept&&complete)return true;
            if(std::chrono::steady_clock::now()-stageStart>std::chrono::seconds(30))return false;
        }
    };

    if(!rangeStage(true,2,"Push the LEFT stick fully UP, DOWN, LEFT and RIGHT. Touch each outer edge; press A to accept. B cancels without saving."))
    {
        a.lastResult=cancel?"Calibration cancelled; no settings were changed":"Left stick outer-range calibration was not completed";
        restoreMuosInputd();in.reopen();return false;
    }
    cancel=false;
    if(!rangeStage(false,3,"Push the RIGHT stick fully UP, DOWN, LEFT and RIGHT. Touch each outer edge; press A to accept. B cancels without saving."))
    {
        a.lastResult=cancel?"Calibration cancelled; no settings were changed":"Right stick outer-range calibration was not completed";
        restoreMuosInputd();in.reopen();return false;
    }

    bool ok=writeCalibrationProfile(a.root/"tsp_muos_stick_calibration.ini",left,right);
    a.lastResult=ok?"Calibration saved: centers and measured full-range scales":"Could not save the stick calibration profile";
    restoreMuosInputd();in.reopen();
    if(ok)calibrationScreen(f,"CALIBRATION SAVED","Both stick centers and all four outer directions per stick were measured. The profile is ready for the muOS OpenMW launcher.",&left,&right,4);
    else calibrationScreen(f,"CALIBRATION EXITED",a.lastResult,&left,&right,4);
    while(true){Action q=in.wait(80);if(q==Action::Back||q==Action::Select||q==Action::Apply||q==Action::Mark)break;}
    a.page=Page::Home;return ok;
}

'''
s=s[:start]+new_block+s[end:]

# Main Inputs construction.
replace_once('Framebuffer fb(getenv("OPENMW51_LAUNCHER_FB")?getenv("OPENMW51_LAUNCHER_FB"):"/dev/fb0");Inputs in;', '''Framebuffer fb(getenv("OPENMW51_LAUNCHER_FB")?getenv("OPENMW51_LAUNCHER_FB"):"/dev/fb0");
        const std::string rootString=a.root.lexically_normal().string();
        // Smart Pro face-button correction is layout-driven: /mnt/mmc is muOS,
        // /userdata is Knulli. Stock/CrossMix stay on the original mapping.
        const bool smartProFaceSwap=(rootString.rfind("/mnt/mmc/",0)==0||rootString.rfind("/userdata/",0)==0||rootString.rfind("/roms/",0)==0||rootString.rfind("/storage/",0)==0);
        Inputs in(smartProFaceSwap);''', 'main Inputs')

# Selftest scale line and helper mapping proof.
replace_once('''    if(calibratedScale(-500,700)!=500||calibratedScale(-1200,1250)!=900||calibratedScale(0,0)!=900)
    {std::cerr<<"selftest: muOS calibration scale policy failed\\n";return 1;}
''', '''    if(calibratedScale(-500,700)!=500||calibratedScale(-1200,1250)!=1200||calibratedScale(0,0)!=900)
    {std::cerr<<"selftest: muOS calibration scale policy failed\\n";return 1;}
    if(mapFaceButtonCode(BTN_SOUTH,false)!=BTN_SOUTH||mapFaceButtonCode(BTN_SOUTH,true)!=BTN_EAST
       ||mapFaceButtonCode(BTN_EAST,true)!=BTN_SOUTH||mapFaceButtonCode(BTN_NORTH,true)!=BTN_WEST
       ||mapFaceButtonCode(BTN_WEST,true)!=BTN_NORTH)
    {std::cerr<<"selftest: Knulli/muOS face-button remap policy failed\\n";return 1;}
''', 'selftest mapping')

# Existing audit expectations.
replace_once("grep -Fq 'TSP_MANAGER_V43_MUOS_CALIBRATOR' \"$CPP\" || fail 16 \"muOS calibrator marker missing\"", "grep -Fq 'TSP_MANAGER_V44_CALIBRATOR_FACE_BUTTONS' \"$CPP\" || fail 16 \"V44 calibrator marker missing\"", 'audit marker')
replace_once("grep -Fq 'Press A to accept; B exits without saving.' \"$CPP\" || fail 16 \"calibration accept controls missing\"", "grep -Fq 'Push the LEFT stick fully UP, DOWN, LEFT and RIGHT.' \"$CPP\" || fail 16 \"left outer-range calibration controls missing\"", 'audit controls')

# Add more audits after input reopen check.
replace_once('''    grep -Fq 'in.reopen();' "$CPP" || fail 16 "input-device reopen after calibration missing"
''', '''    grep -Fq 'in.reopen();' "$CPP" || fail 16 "input-device reopen after calibration missing"
    grep -Fq 'TSP_MANAGER_V44_FACE_BUTTONS' "$CPP" || fail 16 "Knulli/muOS face-button correction marker missing"
    grep -Fq 'mapFaceButtonCode' "$CPP" || fail 16 "face-button mapping helper missing"
    grep -Fq 'Inputs in(smartProFaceSwap)' "$CPP" || fail 16 "layout-aware manager input construction missing"
    grep -Fq 'Touch each outer edge' "$CPP" || fail 16 "outer-range calibration instruction missing"
    grep -Fq 'calibratedScale(-1200,1250)!=1200' "$CPP" || fail 16 "calibration no longer records full-range scale"
''', 'audit additions')

# Fix preflight directory-only selection, retaining the user's exact muOS path.
old='''PORT=""
# TSP_PORTABLE_ROOT_V1: TrimUI first, then batocera/Knulli.
for candidate in /mnt/SDCARD/Roms/PORTS /mnt/sdcard/mmcblk1p1/Roms/PORTS /userdata/roms/ports /roms/ports /storage/roms/ports /mnt/mmc/ROMS/Ports; do [ -d "$candidate" ] && PORT="$candidate" && break; done
[ -n "$PORT" ] || { echo 'ERROR PORTS directory not found'; exit 6; }
[ -f "$PORT/OpenMW_Manager.sh" ] || { echo "ERROR $PORT/OpenMW_Manager.sh missing"; exit 7; }'''
new='''PORT=""
# TSP_PORTABLE_ROOT_V2: choose the first PORTS layout that actually contains
# OpenMW_Manager.sh. The real muOS Ports location remains /mnt/mmc/ROMS/Ports;
# /roms/ports may exist as a convenience directory without the manager.
for candidate in /mnt/SDCARD/Roms/PORTS /mnt/sdcard/mmcblk1p1/Roms/PORTS /userdata/roms/ports /roms/ports /storage/roms/ports /mnt/mmc/ROMS/Ports; do
    if [ -f "$candidate/OpenMW_Manager.sh" ]; then
        PORT="$candidate"
        break
    fi
done
[ -n "$PORT" ] || { echo 'ERROR OpenMW_Manager.sh not found in any known PORTS layout'; exit 6; }
[ -f "$PORT/OpenMW_Manager.sh" ] || { echo "ERROR $PORT/OpenMW_Manager.sh missing"; exit 7; }'''
replace_once(old,new,'PORT preflight')

# Add audit for the preflight fix right after the path audit marker.
replace_once('''    echo "PASS clean-layout path audit"
''', '''    echo "PASS clean-layout path audit"
    grep -Fq 'TSP_PORTABLE_ROOT_V2' "$0" || fail 16 "PORTS preflight is still directory-only"
    grep -Fq 'if [ -f "$candidate/OpenMW_Manager.sh" ]; then' "$0" || fail 16 "PORTS preflight does not verify the manager file"
    grep -Fq '/mnt/mmc/ROMS/Ports' "$0" || fail 16 "correct muOS Ports path disappeared"
''', 'preflight audit')

p.write_text(s)
print('patched:',p)

PY

echo
echo "===== V44 HOST SELFTEST ====="
set +e
bash "$INSTALLER" selftest 2>&1 | tee /tmp/openmw-v44-selftest.txt
RC=${PIPESTATUS[0]}
set -e
cat /tmp/openmw-v44-selftest.txt >> "$LOG" 2>/dev/null || true
printf "\n[V44 patch] %s rc=%s\n" "$(date)" "$RC" >> "$LOG" 2>/dev/null || true
if [ "$RC" -ne 0 ]; then
    echo "ERROR: V44 host selftest failed; installer was left patched but NOT installed."
    exit "$RC"
fi

echo
echo "=============================================="
echo "V44 PATCH COMPLETE"
echo "=============================================="
echo "Installer: $INSTALLER"
echo "Backup:    $BACKUP"
echo "Log:       $LOG"
