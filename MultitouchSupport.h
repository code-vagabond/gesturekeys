// Layout of Apple's private MultitouchSupport contact struct (stable since ~10.6).
// Functions are resolved at runtime via dlsym, so only types live here.
#include <stdint.h>
#include <stdbool.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;

typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int state;          // 4 = make touch, 5 = touching, 6 = break touch, 7 = lingering
    int fingerID;
    int handID;
    MTVector normalized; // 0..1, origin bottom-left
    float size;
    int field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolute;
    int field14;
    int field15;
    float density;
} MTTouch;
