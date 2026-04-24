#ifndef ProjectMBridge_h
#define ProjectMBridge_h

#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <GLKit/GLKit.h>
#include <dlfcn.h>

// projectM C API headers
#include "projectM-4/projectM.h"
#include "projectM-4/audio.h"
#include "projectM-4/core.h"
#include "projectM-4/parameters.h"
#include "projectM-4/render_opengl.h"
#include "projectM-4/callbacks.h"

// GL function loader for tvOS — resolves GL entry points via dlsym.
// Used as the load_proc argument to projectm_create_with_opengl_load_proc().
void* projectm_tv_gl_load_proc(const char* name, void* user_data);

#endif
