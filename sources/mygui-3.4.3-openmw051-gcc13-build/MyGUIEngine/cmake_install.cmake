# Install script for directory: /root/mygui-3.4.3-src/MyGUIEngine

# Set the install prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX "/root/mygui-3.4.3-openmw051-gcc13-install")
endif()
string(REGEX REPLACE "/$" "" CMAKE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

# Set the install configuration name.
if(NOT DEFINED CMAKE_INSTALL_CONFIG_NAME)
  if(BUILD_TYPE)
    string(REGEX REPLACE "^[^A-Za-z0-9_]+" ""
           CMAKE_INSTALL_CONFIG_NAME "${BUILD_TYPE}")
  else()
    set(CMAKE_INSTALL_CONFIG_NAME "Release")
  endif()
  message(STATUS "Install configuration: \"${CMAKE_INSTALL_CONFIG_NAME}\"")
endif()

# Set the component getting installed.
if(NOT CMAKE_INSTALL_COMPONENT)
  if(COMPONENT)
    message(STATUS "Install component: \"${COMPONENT}\"")
    set(CMAKE_INSTALL_COMPONENT "${COMPONENT}")
  else()
    set(CMAKE_INSTALL_COMPONENT)
  endif()
endif()

# Install shared libraries without execute permission?
if(NOT DEFINED CMAKE_INSTALL_SO_NO_EXE)
  set(CMAKE_INSTALL_SO_NO_EXE "1")
endif()

# Is this installation the result of a crosscompile?
if(NOT DEFINED CMAKE_CROSSCOMPILING)
  set(CMAKE_CROSSCOMPILING "FALSE")
endif()

# Set path to fallback-tool for dependency-resolution.
if(NOT DEFINED CMAKE_OBJDUMP)
  set(CMAKE_OBJDUMP "/usr/bin/objdump")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(CMAKE_INSTALL_CONFIG_NAME MATCHES "^([Rr][Ee][Ll][Ee][Aa][Ss][Ee]|[Nn][Oo][Nn][Ee]|)$")
    if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3" AND
       NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3")
      file(RPATH_CHECK
           FILE "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3"
           RPATH "")
    endif()
    file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES "/root/mygui-3.4.3-openmw051-gcc13-build/lib/libMyGUIEngine.so.3.4.3")
    if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3" AND
       NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3")
      if(CMAKE_INSTALL_DO_STRIP)
        execute_process(COMMAND "/usr/bin/strip" "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3")
      endif()
    endif()
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(CMAKE_INSTALL_CONFIG_NAME MATCHES "^([Rr][Ee][Ll][Ee][Aa][Ss][Ee]|[Nn][Oo][Nn][Ee]|)$")
    file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES "/root/mygui-3.4.3-openmw051-gcc13-build/lib/libMyGUIEngine.so")
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(CMAKE_INSTALL_CONFIG_NAME MATCHES "^([Rr][Ee][Ll][Ww][Ii][Tt][Hh][Dd][Ee][Bb][Ii][Nn][Ff][Oo])$")
    if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3" AND
       NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3")
      file(RPATH_CHECK
           FILE "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3"
           RPATH "")
    endif()
    file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES "/root/mygui-3.4.3-openmw051-gcc13-build/lib/libMyGUIEngine.so.3.4.3")
    if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3" AND
       NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3")
      if(CMAKE_INSTALL_DO_STRIP)
        execute_process(COMMAND "/usr/bin/strip" "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3")
      endif()
    endif()
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(CMAKE_INSTALL_CONFIG_NAME MATCHES "^([Rr][Ee][Ll][Ww][Ii][Tt][Hh][Dd][Ee][Bb][Ii][Nn][Ff][Oo])$")
    file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES "/root/mygui-3.4.3-openmw051-gcc13-build/lib/libMyGUIEngine.so")
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(CMAKE_INSTALL_CONFIG_NAME MATCHES "^([Mm][Ii][Nn][Ss][Ii][Zz][Ee][Rr][Ee][Ll])$")
    if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3" AND
       NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3")
      file(RPATH_CHECK
           FILE "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3"
           RPATH "")
    endif()
    file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES "/root/mygui-3.4.3-openmw051-gcc13-build/lib/libMyGUIEngine.so.3.4.3")
    if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3" AND
       NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3")
      if(CMAKE_INSTALL_DO_STRIP)
        execute_process(COMMAND "/usr/bin/strip" "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3")
      endif()
    endif()
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(CMAKE_INSTALL_CONFIG_NAME MATCHES "^([Mm][Ii][Nn][Ss][Ii][Zz][Ee][Rr][Ee][Ll])$")
    file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES "/root/mygui-3.4.3-openmw051-gcc13-build/lib/libMyGUIEngine.so")
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(CMAKE_INSTALL_CONFIG_NAME MATCHES "^([Dd][Ee][Bb][Uu][Gg])$")
    if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3" AND
       NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3")
      file(RPATH_CHECK
           FILE "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3"
           RPATH "")
    endif()
    file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES "/root/mygui-3.4.3-openmw051-gcc13-build/lib/libMyGUIEngine.so.3.4.3")
    if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3" AND
       NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3")
      if(CMAKE_INSTALL_DO_STRIP)
        execute_process(COMMAND "/usr/bin/strip" "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMyGUIEngine.so.3.4.3")
      endif()
    endif()
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(CMAKE_INSTALL_CONFIG_NAME MATCHES "^([Dd][Ee][Bb][Uu][Gg])$")
    file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES "/root/mygui-3.4.3-openmw051-gcc13-build/lib/libMyGUIEngine.so")
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/include/MYGUI" TYPE FILE FILES
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ActionController.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Align.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Any.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_BackwardCompatibility.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_BiIndexBase.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Bitwise.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Button.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Canvas.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ChildSkinInfo.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ClipboardManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_WindowsClipboardHandler.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Colour.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ComboBox.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Common.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_CommonStateInfo.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ConsoleLogListener.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Constants.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ControllerEdgeHide.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ControllerFadeAlpha.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ControllerItem.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ControllerManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ControllerPosition.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ControllerRepeatClick.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_CoordConverter.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_DDContainer.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_DDItemInfo.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_DataFileStream.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_DataManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_DataMemoryStream.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_DataStream.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_DataStreamHolder.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Delegate.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_DeprecatedTypes.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_DeprecatedWidgets.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Diagnostic.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_DynLib.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_DynLibManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_EditBox.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_EditText.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Enumerator.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_EventPair.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Exception.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_FactoryManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_FileLogListener.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_FlowDirection.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_FontData.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_FontManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_GenericFactory.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_GeometryUtility.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Gui.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_IBItemInfo.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ICroppedRectangle.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_IDataStream.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_IFont.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_IItem.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_IItemContainer.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ILayer.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ILayerItem.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ILayerNode.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ILogFilter.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ILogListener.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_IObject.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_IPointer.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_IRenderTarget.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_IResource.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ISerializable.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_IStateInfo.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ISubWidget.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ISubWidgetRect.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ISubWidgetText.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ITexture.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_IUnlinkWidget.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_IVertexBuffer.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ImageBox.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ImageInfo.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_InputManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ItemBox.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_KeyCode.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_LanguageManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_LayerItem.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_LayerManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_LayerNode.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_LayoutData.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_LayoutManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_LevelLogFilter.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ListBox.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_LogLevel.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_LogManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_LogSource.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_LogStream.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Macros.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_MainSkin.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_MaskPickInfo.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_MenuBar.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_MenuControl.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_MenuItem.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_MenuItemType.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_MouseButton.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_MultiListBox.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_MultiListItem.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_OverlappedLayer.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Platform.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Plugin.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_PluginManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_PointerManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_PolygonalSkin.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_PopupMenu.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Precompiled.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Prerequest.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ProgressBar.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_RTTI.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_RenderFormat.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_RenderItem.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_RenderManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_RenderTargetInfo.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ResizingPolicy.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ResourceImageSet.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ResourceImageSetData.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ResourceImageSetPointer.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ResourceLayout.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ResourceManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ResourceManualFont.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ResourceManualPointer.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ResourceSkin.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ResourceTrueTypeFont.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_RotatingSkin.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ScrollBar.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ScrollView.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ScrollViewBase.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_SharedLayer.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_SharedLayerNode.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_SimpleText.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Singleton.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_SkinItem.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_SkinManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_StringUtility.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_SubSkin.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_SubWidgetBinding.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_SubWidgetInfo.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_SubWidgetManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_TCoord.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_TPoint.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_TRect.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_TSize.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_TabControl.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_TabItem.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_TextBox.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_TextChangeHistory.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_TextIterator.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_TextView.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_TextViewData.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_TextureUtility.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_TileRect.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Timer.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_ToolTipManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Types.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_UString.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Version.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_VertexData.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Widget.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_WidgetDefines.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_WidgetInput.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_WidgetManager.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_WidgetStyle.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_WidgetToolTip.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_WidgetTranslate.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_WidgetUserData.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_Window.h"
    "/root/mygui-3.4.3-src/MyGUIEngine/include/MyGUI_XmlDocument.h"
    )
endif()

string(REPLACE ";" "\n" CMAKE_INSTALL_MANIFEST_CONTENT
       "${CMAKE_INSTALL_MANIFEST_FILES}")
if(CMAKE_INSTALL_LOCAL_ONLY)
  file(WRITE "/root/mygui-3.4.3-openmw051-gcc13-build/MyGUIEngine/install_local_manifest.txt"
     "${CMAKE_INSTALL_MANIFEST_CONTENT}")
endif()
