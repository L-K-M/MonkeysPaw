// Renders the Wish Card's stop-motion monkey paw frames (§24.7).
//
// A small signed-distance puppet: forearm with matted fur, braided cord and
// brass medallion, a gaunt hand of tendons and knuckles, and four fingers of
// three phalanges with hooked horn claws. It is raymarched orthographically,
// underlit by the card, then wiry hair is stroked with cairo. Each frame
// re-seeds the hair jitter so the fur "boils" between frames like a handled
// puppet. The index finger curls over frames 1 to 5 with its claw kept on the
// card plane, so its tip path is the gouge `PawTake` draws on the paper.
//
// Output: wish-paw-NN@2x.png (2 px per point) and take.txt (image size,
// anchor, gouge path and per-frame gouge progress for PawTake). preview.c
// composites the frames over a mock card. `render-paw <dir> probe` prints
// hand bounds per frame for framing.
//
// Build: cc -O2 -o render-paw render-paw.c -I<sysroot>/usr/include/cairo -lcairo -lm -lpthread
// Run:   render-paw <output directory>

#include <cairo.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------- vectors --

typedef struct { float x, y, z; } v3;

static inline v3 V(float x, float y, float z) { return (v3){x, y, z}; }
static inline v3 add(v3 a, v3 b) { return V(a.x + b.x, a.y + b.y, a.z + b.z); }
static inline v3 sub(v3 a, v3 b) { return V(a.x - b.x, a.y - b.y, a.z - b.z); }
static inline v3 mul(v3 a, float s) { return V(a.x * s, a.y * s, a.z * s); }
static inline v3 hadamard(v3 a, v3 b) { return V(a.x * b.x, a.y * b.y, a.z * b.z); }
static inline float dot(v3 a, v3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static inline v3 cross(v3 a, v3 b) { return V(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x); }
static inline float len(v3 a) { return sqrtf(dot(a, a)); }
static inline v3 norm(v3 a) { float l = len(a); return l > 1e-9f ? mul(a, 1.0f / l) : V(0, 0, 1); }
static inline float clampf(float x, float lo, float hi) { return x < lo ? lo : x > hi ? hi : x; }
static inline float mixf(float a, float b, float t) { return a + (b - a) * t; }
static inline v3 mixv(v3 a, v3 b, float t) { return add(a, mul(sub(b, a), t)); }
static inline float smoothstepf(float a, float b, float x) { float t = clampf((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); }

// Rotation of v about unit axis k by angle a (Rodrigues).
static v3 rotate(v3 v, v3 k, float a) {
    float c = cosf(a), s = sinf(a);
    return add(add(mul(v, c), mul(cross(k, v), s)), mul(k, dot(k, v) * (1 - c)));
}

// ------------------------------------------------------------------ noise --

static inline float hash3(int x, int y, int z) {
    uint32_t h = (uint32_t)x * 374761393u + (uint32_t)y * 668265263u + (uint32_t)z * 2147483647u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return (float)((h ^ (h >> 16)) & 0xffffff) / (float)0xffffff;
}

static float vnoise(v3 p) {
    int ix = (int)floorf(p.x), iy = (int)floorf(p.y), iz = (int)floorf(p.z);
    float fx = p.x - ix, fy = p.y - iy, fz = p.z - iz;
    fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy); fz = fz * fz * (3 - 2 * fz);
    float a = mixf(hash3(ix, iy, iz), hash3(ix + 1, iy, iz), fx);
    float b = mixf(hash3(ix, iy + 1, iz), hash3(ix + 1, iy + 1, iz), fx);
    float c = mixf(hash3(ix, iy, iz + 1), hash3(ix + 1, iy, iz + 1), fx);
    float d = mixf(hash3(ix, iy + 1, iz + 1), hash3(ix + 1, iy + 1, iz + 1), fx);
    return mixf(mixf(a, b, fy), mixf(c, d, fy), fz);
}

static float fbm(v3 p) {
    float s = 0, a = 0.5f;
    for (int i = 0; i < 4; i++) { s += a * vnoise(p); p = mul(p, 2.03f); a *= 0.5f; }
    return s;
}

// Cellular crack pattern: 0 on cell borders, rising toward cell centres.
static float cells(float u, float v) {
    int iu = (int)floorf(u), iv = (int)floorf(v);
    float d1 = 9, d2 = 9;
    for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
        float cu = iu + i + hash3(iu + i, iv + j, 7), cv = iv + j + hash3(iu + i, iv + j, 13);
        float d = (u - cu) * (u - cu) + (v - cv) * (v - cv);
        if (d < d1) { d2 = d1; d1 = d; } else if (d < d2) d2 = d;
    }
    return clampf((sqrtf(d2) - sqrtf(d1)) * 2.2f, 0, 1);
}

// Deterministic per-frame random numbers for strand boil and tremor.
static uint32_t rng_state;
static float rnd(void) { rng_state = rng_state * 1664525u + 1013904223u; return (float)(rng_state >> 8) / 16777216.0f; }
static float rnds(void) { return rnd() * 2 - 1; }

// --------------------------------------------------------------- puppet --

enum Material { SKIN, CLAW, FUR, CORD, BRASS, NONE };

typedef struct {
    v3 a, b;          // endpoints, world
    float ra, rb;     // radii at a and b
    v3 u, v, w;       // frame attached to the bone: u along, v/w around
    float blend;      // smooth-union radius with the skin group
    int material;
    float length;
    int curler;       // part of the curling finger (for anchor tracking)
} Prim;

#define MAX_PRIMS 96
typedef struct {
    Prim p[MAX_PRIMS];
    int n;
    v3 cordCentre, cordAxis; float cordMajor, cordMinor;
    v3 medal, medalNormal, medalUp; float medalRadius;
    v3 clawTip;       // the curling finger's claw tip, world
    v3 lightKey, lightFill, lightShadow;
    float flicker;
} Scene;

static void prim(Scene *s, v3 a, v3 b, float ra, float rb, v3 side, float blend, int material, int curler) {
    Prim *p = &s->p[s->n++];
    p->a = a; p->b = b; p->ra = ra; p->rb = rb;
    p->u = norm(sub(b, a));
    p->v = norm(sub(side, mul(p->u, dot(side, p->u))));
    p->w = cross(p->u, p->v);
    p->blend = blend; p->material = material; p->length = len(sub(b, a)); p->curler = curler;
}

// iq's round cone.
static float sdRoundCone(v3 p, v3 a, v3 b, float r1, float r2) {
    v3 ba = sub(b, a);
    float l2 = dot(ba, ba), rr = r1 - r2, a2 = l2 - rr * rr, il2 = 1.0f / l2;
    v3 pa = sub(p, a);
    float y = dot(pa, ba), z = y - l2;
    v3 xv = sub(mul(pa, l2), mul(ba, y));
    float x2 = dot(xv, xv), y2 = y * y * l2, z2 = z * z * l2;
    float k = (rr > 0 ? 1 : rr < 0 ? -1 : 0) * rr * rr * x2;
    if ((z > 0 ? 1 : -1) * a2 * z2 > k) return sqrtf(x2 + z2) * il2 - r2;
    if ((y > 0 ? 1 : -1) * a2 * y2 < k) return sqrtf(x2 + y2) * il2 - r1;
    return (sqrtf(x2 * a2 * il2) + y * rr) * il2 - r1;
}

static inline float smin(float a, float b, float k) {
    if (k <= 0) return fminf(a, b);
    float h = fmaxf(k - fabsf(a - b), 0) / k;
    return fminf(a, b) - h * h * k * 0.25f;
}

// Signed distance with material and the nearest skin bone.
static float scene_sdf(const Scene *s, v3 q, int *material, int *bone) {
    float skin = 1e9f, claw = 1e9f, fur = 1e9f;
    float nearest = 1e9f; int nb = -1, cb = -1;
    for (int i = 0; i < s->n; i++) {
        const Prim *p = &s->p[i];
        float d = sdRoundCone(q, p->a, p->b, p->ra, p->rb);
        if (p->material == SKIN) {
            if (d < nearest) { nearest = d; nb = i; }
            skin = smin(skin, d, p->blend);
        } else if (p->material == CLAW) {
            if (d < claw) { claw = d; cb = i; }
        } else if (p->material == FUR) {
            // Matted, shaggy fur: displace outward by streaky noise.
            v3 l = sub(q, p->a);
            float t = dot(l, p->u);
            float n = fbm(V(dot(l, p->v) * 0.22f, t * 0.05f, dot(l, p->w) * 0.22f));
            d -= 5.5f * n;
            if (d < fur) { fur = d; if (nb < 0) nb = i; }
        }
    }
    // Braided cord around the wrist.
    v3 c = sub(q, s->cordCentre);
    float along = dot(c, s->cordAxis);
    v3 radial = sub(c, mul(s->cordAxis, along));
    float rl = len(radial);
    float cord = sqrtf((rl - s->cordMajor) * (rl - s->cordMajor) + along * along) - s->cordMinor;
    // Brass medallion: a thin disc hanging from the cord.
    v3 m = sub(q, s->medal);
    float mz = dot(m, s->medalNormal);
    float mr = len(sub(m, mul(s->medalNormal, mz)));
    float medal = fmaxf(mr - s->medalRadius, fabsf(mz) - 1.1f);
    medal = fminf(medal, 0) + len(V(fmaxf(mr - s->medalRadius, 0), fmaxf(fabsf(mz) - 1.1f, 0), 0)) - 0.25f;

    float d = skin; int mat = SKIN; int b = nb;
    if (claw < d) { d = claw; mat = CLAW; b = cb; }
    if (fur < d) { d = smin(d, fur, 3); mat = FUR; }
    if (cord < d) { d = cord; mat = CORD; }
    if (medal < d) { d = medal; mat = BRASS; }
    if (material) *material = mat;
    if (bone) *bone = b;
    return d;
}

static float sdf(const Scene *s, v3 q) { return scene_sdf(s, q, NULL, NULL); }

// The rotations are applied yaw (about the arm), pitch (onto the card), then
// roll (in the image plane); `lift` raises the hand toward the viewer.
static v3 PLACE_DIR(v3 d, float yaw, float pitch, float roll) {
    float cy = cosf(yaw), sy = sinf(yaw);
    d = V(d.x * cy + d.z * sy, d.y, -d.x * sy + d.z * cy);
    float cp = cosf(pitch), sp = sinf(pitch);
    d = V(d.x, d.y * cp - d.z * sp, d.y * sp + d.z * cp);
    float cr = cosf(roll), sr = sinf(roll);
    return V(d.x * cr - d.y * sr, d.x * sr + d.y * cr, d.z);
}

static v3 place(v3 p, float yaw, float pitch, float roll, float lift) {
    v3 q = PLACE_DIR(p, yaw, pitch, roll);
    return add(q, V(0, 0, 60 + lift));
}

// ------------------------------------------------------------------ pose --

typedef struct {
    float curl;          // 0 straight .. 1 hooked (index finger)
    float lift;          // hand raised off the card, points
    float splay;         // extra finger spread, radians
    float tremor;        // random pose noise amplitude, radians
    float pitch;         // extra hand pitch, radians
    uint32_t seed;
} Pose;

// Builds the puppet for one frame. Hand space: wrist at the origin, fingers
// along -y, back of the hand toward +z, index finger on -x. The whole hand is
// then turned three-quarters, pitched onto the card and rolled to reach in
// from the top right.
static void build(Scene *s, Pose pose) {
    memset(s, 0, sizeof(*s));
    rng_state = pose.seed;

    const float yaw = 0.55f, pitch = 0.42f + pose.pitch, roll = -0.46f;
    #define PLACE(p) place(p, yaw, pitch, roll, pose.lift)

    v3 X = V(1, 0, 0), Z = V(0, 0, 1);

    // Forearm and matted fur; the elbow is far outside the frame.
    v3 elbow = V(4, 150, 10), wrist = V(0, 6, 3);
    prim(s, wrist, elbow, 15, 21, Z, 0, SKIN, 0);
    prim(s, V(0, 14, 3), elbow, 17, 23, Z, 0, FUR, 0);

    // Metacarpals: tendon ridges under shrunken skin, plus a palm slab.
    float kx[4] = {-17.5f, -6.0f, 5.5f, 16.0f};
    float ky[4] = {-60, -64, -62, -56};
    float wx[4] = {-8, -3, 2, 7};
    for (int i = 0; i < 4; i++)
        prim(s, V(wx[i], -2, 2), V(kx[i], ky[i], 3.5f), 6.0f, 5.4f, X, 9, SKIN, 0);
    prim(s, V(-4, -8, -3), V(-1, -50, -3.5f), 11, 12, X, 12, SKIN, 0);
    prim(s, V(3, -8, -3), V(6, -48, -3.5f), 10, 11, X, 12, SKIN, 0);

    // Fingers: lengths of three phalanges, spread, resting flexion.
    float lengths[4][3] = {{32, 24, 17}, {37, 27, 18}, {35, 25, 17}, {28, 20, 14}};
    float spread[4] = {-0.20f, -0.06f, 0.08f, 0.22f};
    float rest[4][3] = {{0.10f, 0.20f, 0.14f}, {0.16f, 0.26f, 0.18f}, {0.12f, 0.30f, 0.16f}, {0.20f, 0.34f, 0.22f}};
    float hooked[3] = {1.05f, 1.75f, 1.25f};
    float radii[4] = {5.0f, 4.3f, 3.7f, 3.1f};

    for (int f = 0; f < 4; f++) {
        int curler = f == 0;
        float sp = spread[f] * (1 + pose.splay * 3);
        v3 dir = V(sinf(sp), -cosf(sp), 0);
        v3 axis = norm(cross(dir, Z));  // flexion axis; positive bends toward the palm
        v3 joint = V(kx[f], ky[f], 3.5f);
        float scale = f == 3 ? 0.88f : 1.0f;

        // A fat, bony knuckle at the base.
        prim(s, joint, add(joint, mul(dir, 0.5f)), 6.6f * scale, 6.2f * scale, axis, 4, SKIN, curler);

        float bend = 0;
        for (int k = 0; k < 3; k++) {
            float angle = rest[f][k] + pose.tremor * rnds();
            if (curler) angle = mixf(angle, hooked[k], pose.curl);
            bend += angle;
            v3 d = rotate(dir, axis, -bend);
            float L = lengths[f][k];
            v3 next = add(joint, mul(d, L));
            float r0 = radii[k] * scale, r1 = radii[k + 1] * scale;
            prim(s, joint, next, r0, r1, axis, 2.2f, SKIN, curler);
            // Knobbly joints: a bulge where the next phalanx starts.
            if (k < 2) prim(s, next, add(next, mul(d, 0.3f)), r1 + 0.7f, r1 + 0.5f, axis, 7.0f, SKIN, curler);
            joint = next;

            if (k == 2) {
                // A thick horn claw rooted on the back of the tip, hooking
                // toward the palm.
                v3 c0 = add(sub(joint, mul(d, 4.0f)), mul(cross(axis, d), -1.6f));
                float hook = bend;
                float clawLen[4] = {10.5f, 9.5f, 8.5f, 7.5f};
                float clawR[5] = {3.3f, 2.8f, 2.0f, 1.1f, 0.2f};
                for (int c = 0; c < 4; c++) {
                    hook += 0.36f;
                    v3 cd = rotate(dir, axis, -hook);
                    v3 c1 = add(c0, mul(cd, clawLen[c] * scale));
                    prim(s, c0, c1, clawR[c] * scale, clawR[c + 1] * scale, axis, 0, CLAW, curler);
                    c0 = c1;
                }
                if (curler) s->clawTip = c0;
            }
        }
    }

    // Cord and medallion in hand space.
    v3 cordCentre = V(0, 22, 3), cordAxis = norm(sub(elbow, wrist));
    v3 medal = V(-1, 12, 25);

    // Place every primitive in the world.
    for (int i = 0; i < s->n; i++) {
        Prim *p = &s->p[i];
        p->a = PLACE(p->a); p->b = PLACE(p->b);
        v3 side = PLACE_DIR(p->v, yaw, pitch, roll);
        p->u = norm(sub(p->b, p->a));
        p->v = norm(sub(side, mul(p->u, dot(side, p->u))));
        p->w = cross(p->u, p->v);
    }
    s->clawTip = PLACE(s->clawTip);

    // Keep the curling claw on the card plane (z = 0) so it gouges the paper
    // as it curls; `lift` raises it off the card.
    v3 shift = V(0, 0, pose.lift - s->clawTip.z);
    for (int i = 0; i < s->n; i++) { s->p[i].a = add(s->p[i].a, shift); s->p[i].b = add(s->p[i].b, shift); }
    s->clawTip = add(s->clawTip, shift);
    s->cordCentre = add(PLACE(cordCentre), shift);
    s->cordAxis = norm(PLACE_DIR(cordAxis, yaw, pitch, roll));
    s->cordMajor = 19.5f; s->cordMinor = 2.6f;
    s->medal = add(PLACE(medal), shift);
    s->medalNormal = norm(PLACE_DIR(V(0.15f, -0.25f, 1), yaw, pitch, roll));
    s->medalUp = norm(PLACE_DIR(V(0, 1, 0), yaw, pitch, roll));
    s->medalRadius = 7.5f;

    // Underlit by the card, a cool night fill from above, and a soft room
    // light for the cast shadow.
    s->lightKey = norm(V(-0.35f, -0.62f, 0.70f));
    s->lightFill = norm(V(0.25f, 0.85f, 0.45f));
    s->lightShadow = norm(V(-0.32f, 0.42f, 0.85f));
    s->flicker = 1 + 0.035f * rnds();
}

// --------------------------------------------------------------- shading --

typedef struct { float r, g, b, a; float depth; } Sample;

static v3 normal_at(const Scene *s, v3 p) {
    const float e = 0.05f;
    return norm(V(sdf(s, add(p, V(e, 0, 0))) - sdf(s, sub(p, V(e, 0, 0))),
                  sdf(s, add(p, V(0, e, 0))) - sdf(s, sub(p, V(0, e, 0))),
                  sdf(s, add(p, V(0, 0, e))) - sdf(s, sub(p, V(0, 0, e)))));
}

static float soft_shadow(const Scene *s, v3 o, v3 d, float k) {
    float res = 1, t = 0.6f;
    for (int i = 0; i < 40 && t < 160; i++) {
        float h = sdf(s, add(o, mul(d, t)));
        if (h < 0.002f) return 0;
        res = fminf(res, k * h / t);
        t += clampf(h, 0.4f, 8);
    }
    return clampf(res, 0, 1);
}

static float occlusion(const Scene *s, v3 p, v3 n) {
    float o = 0, w = 1;
    for (int i = 1; i <= 5; i++) {
        float h = 1.4f * i;
        o += w * (h - sdf(s, add(p, mul(n, h))));
        w *= 0.6f;
    }
    return clampf(1 - o * 0.09f, 0, 1);
}

// Leathery relief in the bone's own frame, so it travels with the pose:
// scaly cells, ring wrinkles at the joints and a little grain.
static float relief(const Scene *s, v3 q, int bone) {
    if (bone < 0) return 0;
    const Prim *p = &s->p[bone];
    v3 l = sub(q, p->a);
    float t = dot(l, p->u);
    float ang = atan2f(dot(l, p->w), dot(l, p->v));
    float r = (p->ra + p->rb) * 0.5f;
    float cellsH = cells(t * 0.55f, ang * r * 0.55f);
    float ends = expf(-(t * t) / 10) + expf(-((p->length - t) * (p->length - t)) / 10);
    float rings = 0.5f + 0.5f * sinf(t * 4.6f + 1.6f * vnoise(mul(q, 0.35f)) * 3 + ang * 0.8f);
    float folds = 0.5f + 0.5f * sinf(ang * r * 1.3f + 2.5f * vnoise(mul(q, 0.18f)));
    float grain = vnoise(mul(q, 1.7f));
    return 0.26f * cellsH + 0.30f * rings * ends + 0.33f * folds + 0.14f * grain;
}

static Sample shade(const Scene *s, v3 p, v3 view) {
    int material, bone;
    scene_sdf(s, p, &material, &bone);
    v3 n = normal_at(s, p);

    v3 albedo; float specPower = 18, specAmount = 0.25f, bumpAmount = 0;
    float h = 0;
    switch (material) {
    case SKIN: {
        h = relief(s, p, bone);
        bumpAmount = 0.9f;
        float mottled = fbm(mul(p, 0.08f));
        albedo = mixv(V(0.012f, 0.010f, 0.009f), V(0.105f, 0.092f, 0.078f), clampf(h * 1.1f + mottled * 0.5f - 0.35f, 0, 1));
        // Dry, ashen knuckles and ridges.
        float ridge = clampf(dot(n, s->p[bone >= 0 ? bone : 0].w) * 0.5f + 0.5f, 0, 1);
        albedo = mixv(albedo, V(0.30f, 0.27f, 0.23f), 0.35f * ridge * h * h);
        specPower = 22; specAmount = 0.22f + 0.25f * h;
        break;
    }
    case CLAW: {
        const Prim *c = &s->p[bone];
        float t = clampf(dot(sub(p, c->a), c->u) / fmaxf(c->length, 1), 0, 1);
        int order = 0;
        for (int i = bone; i > 0 && s->p[i - 1].material == CLAW && s->p[i - 1].curler == c->curler; i--) order++;
        float along = clampf((order % 4 + t) / 4.0f, 0, 1);
        albedo = mixv(mixv(V(0.08f, 0.06f, 0.035f), V(0.60f, 0.52f, 0.30f), smoothstepf(0, 0.4f, along)),
                      V(0.05f, 0.035f, 0.02f), smoothstepf(0.72f, 1.0f, along));
        h = 0.5f + 0.5f * sinf(along * 40 + vnoise(mul(p, 0.6f)) * 4);   // growth ridges
        bumpAmount = 0.25f;
        specPower = 70; specAmount = 0.75f;
        break;
    }
    case FUR: {
        float streak = vnoise(V(p.x * 0.5f, p.y * 0.12f, p.z * 0.5f));
        albedo = mixv(V(0.010f, 0.008f, 0.007f), V(0.055f, 0.042f, 0.032f), streak);
        specAmount = 0.05f;
        break;
    }
    case CORD: {
        v3 c = sub(p, s->cordCentre);
        float ang = atan2f(dot(c, cross(s->cordAxis, s->medalUp)), dot(c, s->medalUp));
        float braid = 0.5f + 0.5f * sinf(ang * 22 + dot(c, s->cordAxis) * 2.4f);
        albedo = mixv(V(0.16f, 0.09f, 0.04f), V(0.42f, 0.27f, 0.12f), braid);
        h = braid; bumpAmount = 0.6f; specAmount = 0.1f;
        break;
    }
    default: {
        v3 m = sub(p, s->medal);
        float r = len(sub(m, mul(s->medalNormal, dot(m, s->medalNormal)))) / s->medalRadius;
        float rings = smoothstepf(0.78f, 0.9f, r) + (1 - smoothstepf(0.22f, 0.32f, r));
        albedo = mixv(V(0.16f, 0.10f, 0.035f), V(0.55f, 0.38f, 0.14f), clampf(rings, 0, 1));
        h = rings; bumpAmount = 0.3f; specPower = 40; specAmount = 1.1f;
        break;
    }
    }

    // Bump: tilt the normal against the relief gradient.
    if (bumpAmount > 0 && (material == SKIN || material == CLAW || material == CORD || material == BRASS)) {
        const float e = 0.12f;
        float hx = (material == SKIN) ? relief(s, add(p, V(e, 0, 0)), bone) : h;
        float hy = (material == SKIN) ? relief(s, add(p, V(0, e, 0)), bone) : h;
        float hz = (material == SKIN) ? relief(s, add(p, V(0, 0, e)), bone) : h;
        v3 g = mul(V(hx - h, hy - h, hz - h), 1.0f / e);
        g = sub(g, mul(n, dot(g, n)));
        n = norm(sub(n, mul(g, 0.35f * bumpAmount)));
    }

    float ao = occlusion(s, p, n);
    float keyShadow = soft_shadow(s, add(p, mul(n, 0.3f)), s->lightKey, 10);
    float key = fmaxf(dot(n, s->lightKey), 0) * keyShadow;
    float fill = 0.5f + 0.5f * dot(n, s->lightFill);
    float rim = powf(1 - fmaxf(dot(n, view), 0), 2.6f);
    v3 hk = norm(add(s->lightKey, view));
    float spec = powf(fmaxf(dot(n, hk), 0), specPower) * specAmount * keyShadow;

    v3 amber = V(1.0f, 0.70f, 0.40f), night = V(0.24f, 0.24f, 0.42f);
    v3 c = add(add(mul(hadamard(albedo, amber), 1.5f * key * s->flicker),
                   mul(hadamard(albedo, night), 0.9f * fill * ao)),
               add(mul(amber, spec * 0.7f), mul(V(0.95f, 0.62f, 0.30f), rim * 0.32f * (0.35f + 0.65f * ao))));
    if (material == FUR) c = add(c, mul(V(0.9f, 0.5f, 0.2f), rim * 0.4f));
    c = mul(c, 0.55f + 0.45f * ao);

    Sample out = {c.x, c.y, c.z, 1, p.z};
    return out;
}

// ---------------------------------------------------------------- render --

#define SCALE 2              // pixels per point
#define PUPPET 1.55f          // points per puppet unit
#define SS 3                 // supersampling per axis
typedef struct {
    const Scene *s;
    int width, height;       // pixels
    float ox, oy;            // world coordinates of the image's top-left, points
    float *rgba;             // premultiplied linear, width*height*4
    float *depth;            // world z of the hit, -1e9 when none
    float *shadowCover;      // cast shadow on the card plane, 0..1
    int row;
    pthread_mutex_t lock;
} Job;

static void render_pixel(Job *job, int x, int y) {
    float r = 0, g = 0, b = 0, a = 0, depth = -1e9f, shadow = 0;
    v3 view = V(0, 0, 1);
    for (int sy = 0; sy < SS; sy++) for (int sx = 0; sx < SS; sx++) {
        float wx = job->ox + (x + (sx + 0.5f) / SS) / (SCALE * PUPPET);
        float wy = job->oy - (y + (sy + 0.5f) / SS) / (SCALE * PUPPET);
        v3 o = V(wx, wy, 220);
        float t = 0; int hit = 0;
        for (int i = 0; i < 160 && t < 300; i++) {
            float d = sdf(job->s, add(o, mul(V(0, 0, -1), t)));
            if (d < 0.01f) { hit = 1; break; }
            t += d * 0.9f;
        }
        if (hit) {
            Sample c = shade(job->s, add(o, mul(V(0, 0, -1), t)), view);
            r += c.r; g += c.g; b += c.b; a += 1;
            if (c.depth > depth) depth = c.depth;
        } else {
            // The card plane is z = 0: cast a soft shadow onto it.
            v3 q = V(wx, wy, 0);
            float sh = soft_shadow(job->s, q, job->s->lightShadow, 3);
            shadow += 1 - sh;
        }
    }
    float n = SS * SS;
    int i = y * job->width + x;
    job->rgba[i * 4 + 0] = r / n; job->rgba[i * 4 + 1] = g / n;
    job->rgba[i * 4 + 2] = b / n; job->rgba[i * 4 + 3] = a / n;
    job->depth[i] = depth;
    job->shadowCover[i] = shadow / n;
}

static void *worker(void *arg) {
    Job *job = arg;
    for (;;) {
        pthread_mutex_lock(&job->lock);
        int y = job->row++;
        pthread_mutex_unlock(&job->lock);
        if (y >= job->height) return NULL;
        for (int x = 0; x < job->width; x++) render_pixel(job, x, y);
    }
}

static inline float tonemap(float x) {
    x *= 0.62f;
    x = (x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f);
    return powf(clampf(x, 0, 1), 1 / 2.2f);
}

// ------------------------------------------------------------------- fur --

typedef struct { int bone; float t, ang, length, lean; } Strand;
// Room for every rule below: arm fur, hand hair and sparse finger hairs.
#define MAX_STRANDS 8000
static Strand strands[MAX_STRANDS];
static int strandCount;

// Strand roots are fixed in bone space; only their jitter changes per frame.
static void plant_strands(const Scene *s) {
    rng_state = 99;
    strandCount = 0;
    for (int i = 0; i < s->n && strandCount < MAX_STRANDS; i++) {
        const Prim *p = &s->p[i];
        int count = 0; float minL = 0, maxL = 0, lean = 0;
        if (p->material == FUR) { count = 2600; minL = 7; maxL = 24; lean = 0.55f; }
        else if (p->material == SKIN && i < 2) { count = 400; minL = 5; maxL = 14; lean = 0.5f; }
        else if (p->material == SKIN && i >= 2 && i < 8) { count = 480; minL = 5; maxL = 14; lean = 0.55f; }
        else if (p->material == SKIN && !p->curler && p->length > 20) { count = 14; minL = 3; maxL = 7; lean = 0.75f; }
        else if (p->material == SKIN && p->curler && p->length > 20) { count = 14; minL = 3; maxL = 7; lean = 0.75f; }
        for (int k = 0; k < count && strandCount < MAX_STRANDS; k++) {
            Strand *st = &strands[strandCount++];
            st->bone = i;
            st->t = rnd();
            // Hand hairs grow on the side facing the viewer.
            float facing = atan2f(p->w.z, p->v.z);
            st->ang = p->material == FUR ? rnds() * 3.1416f : facing + rnds() * 1.25f;
            st->length = mixf(minL, maxL, powf(rnd(), 1.6f));
            st->lean = lean;
        }
    }
    // A full budget silently drops the hair of later bones.
    if (strandCount == MAX_STRANDS) fprintf(stderr, "render-paw: strand budget exhausted; raise MAX_STRANDS\n");
}

static void draw_strands(cairo_t *cr, const Scene *s, const Job *job, const unsigned char *pixels, int stride, uint32_t seed) {
    rng_state = seed;
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    for (int i = 0; i < strandCount; i++) {
        Strand *st = &strands[i];
        const Prim *p = &s->p[st->bone];
        float t = st->t * p->length;
        float r = mixf(p->ra, p->rb, st->t);
        r += p->material == FUR ? 2.5f : 2.2f;
        v3 radial = add(mul(p->v, cosf(st->ang)), mul(p->w, sinf(st->ang)));
        v3 root = add(add(p->a, mul(p->u, t)), mul(radial, r));

        // Lie along the bone toward the fingers, bristling outward; boil.
        v3 along = p->material == FUR || st->bone < 2 ? mul(p->u, -1) : p->u;
        v3 dir = norm(add(mul(along, st->lean), mul(radial, 1 - st->lean + 0.25f)));
        dir = norm(add(dir, V(rnds() * 0.28f, rnds() * 0.28f, rnds() * 0.2f)));
        float length = st->length * (0.88f + 0.24f * rnd());
        v3 bendTo = norm(add(dir, mul(V(0, -1, 0), 0.35f)));
        v3 mid = add(root, mul(dir, length * 0.5f));
        v3 tip = add(mid, mul(bendTo, length * 0.5f));

        float px = (root.x - job->ox) * SCALE * PUPPET, py = (job->oy - root.y) * SCALE * PUPPET;
        int ix = (int)px, iy = (int)py;
        if (ix < 0 || iy < 0 || ix >= job->width || iy >= job->height) continue;
        float zbuf = job->depth[iy * job->width + ix];
        if (zbuf > root.z + 2.5f) continue;   // root hidden behind the paw

        float tx = (tip.x - job->ox) * SCALE * PUPPET, ty = (job->oy - tip.y) * SCALE * PUPPET;
        int jx = (int)tx, jy = (int)ty;
        int outside = jx < 0 || jy < 0 || jx >= job->width || jy >= job->height
            || pixels[jy * stride + jx * 4 + 3] < 120;

        // Root colour from the shaded paw; tips over the background catch the
        // card's glow like the icon's backlit fur.
        const unsigned char *rc = &pixels[iy * stride + ix * 4];
        float br = rc[2] / 255.0f, bg = rc[1] / 255.0f, bb = rc[0] / 255.0f;
        float lift = 0.85f + 0.5f * rnd();
        cairo_pattern_t *pat = cairo_pattern_create_linear(px, py, tx, ty);
        int handHair = p->material == SKIN;
        if (handHair) { br = br * 0.5f + 0.13f; bg = bg * 0.5f + 0.10f; bb = bb * 0.5f + 0.075f; }
        cairo_pattern_add_color_stop_rgba(pat, 0, br * 0.7f, bg * 0.7f, bb * 0.7f, 0.95f);
        if (outside)
            cairo_pattern_add_color_stop_rgba(pat, 1, 0.62f, 0.38f, 0.17f, 0.7f);
        else
            cairo_pattern_add_color_stop_rgba(pat, 1, fminf(br * lift + 0.05f, 1), fminf(bg * lift + 0.03f, 1), bb * lift, 0.85f);
        cairo_set_source(cr, pat);
        cairo_set_line_width(cr, (p->material == FUR ? 0.9f : 0.7f) * (0.7f + 0.6f * rnd()));
        float mx = (mid.x - job->ox) * SCALE * PUPPET, my = (job->oy - mid.y) * SCALE * PUPPET;
        cairo_move_to(cr, px, py);
        cairo_curve_to(cr, mx, my, mx, my, tx, ty);
        cairo_stroke(cr);
        cairo_pattern_destroy(pat);
    }
}

// ----------------------------------------------------------------- frames --

typedef struct { Pose pose; const char *note; } FrameSpec;

int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : ".";
    int threads = 16;

    // Curl spacing is uneven on purpose: stop-motion favours the extremes.
    FrameSpec frames[] = {
        {{0.00f, 22, 0.12f, 0.06f, -0.10f, 101}, "lurch in"},
        {{0.00f, 0, 0.04f, 0.05f, 0.00f, 102}, "claws touch"},
        {{0.16f, 0, 0.03f, 0.05f, 0.00f, 103}, "curl"},
        {{0.42f, 0, 0.03f, 0.05f, 0.00f, 104}, "curl"},
        {{0.78f, 0, 0.02f, 0.05f, 0.00f, 105}, "curl"},
        {{1.00f, 0, 0.02f, 0.05f, 0.00f, 106}, "hooked"},
        {{1.00f, 0, 0.02f, 0.07f, 0.01f, 107}, "held beat"},
        {{1.00f, 6, 0.00f, 0.05f, -0.06f, 108}, "lift"},
        {{1.00f, 10, 0.00f, 0.05f, -0.10f, 109}, "carry"},
    };
    int frameCount = sizeof(frames) / sizeof(frames[0]);

    // Frame the image around the hooked pose: the image's anchor is the
    // hooked claw tip; the wrist and fur run off the top right.
    const float imageW = 360, imageH = 410, anchorX = 140, anchorY = 260;
    Scene hooked; build(&hooked, frames[5].pose);
    float ox = hooked.clawTip.x - anchorX / PUPPET, oy = hooked.clawTip.y + anchorY / PUPPET;

    // The take table: anchor, then the claw's gouge across the paper while
    // it curls (frames 1 to 5), relative to the anchor in points.
    char tablePath[1024]; snprintf(tablePath, sizeof tablePath, "%s/take.txt", dir);
    FILE *table = fopen(tablePath, "w");
    fprintf(table, "%.0f %.0f %.0f %.0f\n", imageW, imageH, anchorX, anchorY);
    float kx[7], ky[7];
    for (int f = 1; f <= 5; f++) {
        Scene s; build(&s, frames[f].pose);
        kx[f] = (s.clawTip.x - hooked.clawTip.x) * PUPPET; ky[f] = (hooked.clawTip.y - s.clawTip.y) * PUPPET;
    }
    kx[0] = 2 * kx[1] - kx[2]; ky[0] = 2 * ky[1] - ky[2];
    kx[6] = 2 * kx[5] - kx[4]; ky[6] = 2 * ky[5] - ky[4];
    // Catmull-Rom through the tips; progress per frame is the arc length so far.
    float px = kx[1], py = ky[1], length = 0, progress[6] = {0};
    fprintf(table, "path %.1f %.1f\n", px, py);
    for (int seg = 1; seg <= 4; seg++) {
        for (int k = 1; k <= 8; k++) {
            float t = k / 8.0f, t2 = t * t, t3 = t2 * t;
            float x = 0.5f * (2 * kx[seg] + (-kx[seg - 1] + kx[seg + 1]) * t + (2 * kx[seg - 1] - 5 * kx[seg] + 4 * kx[seg + 1] - kx[seg + 2]) * t2 + (-kx[seg - 1] + 3 * kx[seg] - 3 * kx[seg + 1] + kx[seg + 2]) * t3);
            float y = 0.5f * (2 * ky[seg] + (-ky[seg - 1] + ky[seg + 1]) * t + (2 * ky[seg - 1] - 5 * ky[seg] + 4 * ky[seg + 1] - ky[seg + 2]) * t2 + (-ky[seg - 1] + 3 * ky[seg] - 3 * ky[seg + 1] + ky[seg + 2]) * t3);
            length += hypotf(x - px, y - py); px = x; py = y;
            fprintf(table, "path %.1f %.1f\n", x, y);
        }
        progress[seg + 1] = length;
    }
    for (int f = 1; f <= 5; f++) fprintf(table, "progress %d %.3f\n", f, progress[f] / length);
    fclose(table);


    if (argc > 2) {
        for (int f = 0; f < frameCount; f++) {
            Scene s; build(&s, frames[f].pose);
            float minx = 1e9, maxx = -1e9, miny = 1e9, maxy = -1e9;
            for (int i = 2; i < s.n; i++) {
                v3 e[2] = {s.p[i].a, s.p[i].b};
                for (int k = 0; k < 2; k++) {
                    float r = k ? s.p[i].rb : s.p[i].ra;
                    minx = fminf(minx, e[k].x - r); maxx = fmaxf(maxx, e[k].x + r);
                    miny = fminf(miny, e[k].y - r); maxy = fmaxf(maxy, e[k].y + r);
                }
            }
            printf("frame %d hand x %.0f..%.0f y(down) %.0f..%.0f wrist (%.0f, %.0f) tip (%.0f, %.0f) relative to hooked tip\n", f,
                   minx - hooked.clawTip.x, maxx - hooked.clawTip.x, hooked.clawTip.y - maxy, hooked.clawTip.y - miny,
                   s.p[0].a.x - hooked.clawTip.x, hooked.clawTip.y - s.p[0].a.y, s.clawTip.x - hooked.clawTip.x, hooked.clawTip.y - s.clawTip.y);
        }
        return 0;
    }
    Scene rest; build(&rest, frames[1].pose);
    plant_strands(&rest);

    int width = (int)(imageW * SCALE), height = (int)(imageH * SCALE);
    for (int f = 0; f < frameCount; f++) {
        Scene scene; build(&scene, frames[f].pose);
        Job job = {&scene, width, height, ox, oy,
                   calloc((size_t)width * height * 4, sizeof(float)),
                   calloc((size_t)width * height, sizeof(float)),
                   calloc((size_t)width * height, sizeof(float)), 0, PTHREAD_MUTEX_INITIALIZER};
        pthread_t pool[64];
        for (int i = 0; i < threads; i++) pthread_create(&pool[i], NULL, worker, &job);
        for (int i = 0; i < threads; i++) pthread_join(pool[i], NULL);

        cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
        unsigned char *pixels = cairo_image_surface_get_data(surface);
        int stride = cairo_image_surface_get_stride(surface);
        cairo_surface_flush(surface);
        for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) {
            int i = y * width + x;
            float a = job.rgba[i * 4 + 3];
            float edge = fminf(fminf(x, width - 1 - x), height - 1 - y) / (36.0f * SCALE);
            float shadow = job.shadowCover[i] * 0.28f * smoothstepf(0, 1, edge);
            // Paw over its own shadow: premultiplied "over".
            float r = tonemap(a > 0 ? job.rgba[i * 4 + 0] / a : 0) * a;
            float g = tonemap(a > 0 ? job.rgba[i * 4 + 1] / a : 0) * a;
            float b = tonemap(a > 0 ? job.rgba[i * 4 + 2] / a : 0) * a;
            float outA = a + shadow * (1 - a);
            unsigned char *px = &pixels[y * stride + x * 4];
            px[0] = (unsigned char)(clampf(b, 0, 1) * 255 + 0.5f);
            px[1] = (unsigned char)(clampf(g, 0, 1) * 255 + 0.5f);
            px[2] = (unsigned char)(clampf(r, 0, 1) * 255 + 0.5f);
            px[3] = (unsigned char)(clampf(outA, 0, 1) * 255 + 0.5f);
        }
        cairo_surface_mark_dirty(surface);

        // Fur strands need the shaded paw underneath; draw over a copy.
        cairo_surface_t *base = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
        cairo_t *copy = cairo_create(base);
        cairo_set_source_surface(copy, surface, 0, 0);
        cairo_paint(copy);
        cairo_destroy(copy);
        cairo_surface_flush(base);
        cairo_t *cr = cairo_create(surface);
        draw_strands(cr, &scene, &job, cairo_image_surface_get_data(base), cairo_image_surface_get_stride(base),
                     frames[f].pose.seed * 7919u);
        cairo_destroy(cr);
        cairo_surface_destroy(base);

        char path[1024];
        snprintf(path, sizeof path, "%s/wish-paw-%02d@2x.png", dir, f);
        cairo_surface_write_to_png(surface, path);
        float tipX = (scene.clawTip.x - ox) * PUPPET, tipY = (oy - scene.clawTip.y) * PUPPET;
        printf("frame %d (%s): claw tip at (%.1f, %.1f) pt, z %.1f\n", f, frames[f].note, tipX, tipY, scene.clawTip.z);
        cairo_surface_destroy(surface);
        free(job.rgba); free(job.depth); free(job.shadowCover);
    }
    return 0;
}
