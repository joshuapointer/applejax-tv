#import "ProjectMBridge.h"
#import <dlfcn.h>

// Resolve OpenGL ES function pointers at runtime.
// On tvOS, OpenGLES.framework symbols are globally visible once the framework
// is linked, so dlsym(RTLD_DEFAULT, name) finds them.
void* applejax_gl_load_proc(const char* name, void* user_data) {
    (void)user_data;  // unused
    void* symbol = dlsym(RTLD_DEFAULT, name);
    if (!symbol) {
        // Fallback: try loading from the OpenGLES framework explicitly
        static void* gles_handle = NULL;
        if (!gles_handle) {
            gles_handle = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_LAZY);
        }
        if (gles_handle) {
            symbol = dlsym(gles_handle, name);
        }
    }
    return symbol;
}
