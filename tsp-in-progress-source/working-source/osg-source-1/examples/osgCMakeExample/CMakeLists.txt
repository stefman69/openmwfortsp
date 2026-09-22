cmake_minimum_required(VERSION 3.5)

SET(PROJECT_NAME osgCMakeExample)

PROJECT(${PROJECT_NAME})

FIND_PACKAGE(OpenThreads)
FIND_PACKAGE(osg)
FIND_PACKAGE(osgDB)
FIND_PACKAGE(osgUtil)
FIND_PACKAGE(osgGA)
FIND_PACKAGE(osgViewer)

SET(SOURCES
    main.cpp
)

INCLUDE_DIRECTORIES(${OPENTHREADS_INCLUDE_DIR} ${OSG_INCLUDE_DIR})

LINK_DIRECTORIES(${OSG_LIB_DIR})

ADD_EXECUTABLE(${PROJECT_NAME} ${SOURCES})

TARGET_LINK_LIBRARIES(${PROJECT_NAME} ${OSG_LIBRARIES} ${OSGVIEWER_LIBRARIES} ${OSGUTIL_LIBRARIES} ${OSGDB_LIBRARIES} ${OSGGA_LIBRARIES} ${OPENTHREADS_LIBRARIES})

IF(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    # templated types used in OSG plugins and applications need to get the same type ID
    # based on investigation for https://gitlab.com/OpenMW/openmw/-/issues/8039 by the OpenMW team, this is believed to only be necessary for Clang on Linux
    # i.e. not for GCC anywhere, MSVC on Windows or for AppleClang on MacOS
    # it's possible that this is really required by the C++ spec for all platforms and we're just getting away with it everywhere else
    SET_TARGET_PROPERTIES(${TARGET_TARGETNAME} PROPERTIES ENABLE_EXPORTS ON)
ENDIF()
