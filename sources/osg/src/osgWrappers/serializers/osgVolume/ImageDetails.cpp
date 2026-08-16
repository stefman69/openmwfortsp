#include <osgVolume/Layer>
#include <osgDB/ObjectWrapper>
#include <osgDB/InputStream>
#include <osgDB/OutputStream>

static bool checkMatrix( const osgVolume::ImageDetails& details )
{
    return details.getMatrix()!=NULL;
}

static bool readMatrix( osgDB::InputStream& is, osgVolume::ImageDetails& details )
{
    osg::Matrixd matrix; is >> matrix;
    details.setMatrix( new osg::RefMatrix(matrix) );
    return true;
}

static bool writeMatrix( osgDB::OutputStream& os, const osgVolume::ImageDetails& details )
{
    os << *(details.getMatrix()) << osgDB::OutputStream::Endl{};
    return true;
}

REGISTER_OBJECT_WRAPPER( osgVolume_ImageDetails,
                         new osgVolume::ImageDetails,
                         osgVolume::ImageDetails,
                         "osg::Object osgVolume::ImageDetails" )
{
    ADD_VEC4_SERIALIZER( TexelOffset, osg::Vec4() );  // _texelOffset
    ADD_VEC4_SERIALIZER( TexelScale, osg::Vec4() );  // _texelScale
    ADD_USER_SERIALIZER( Matrix );  // _matrix
}
