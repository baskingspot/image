import sys
SRC=sys.argv[1]
# phases.py: patches a copy of src at '+SRC+' with rdtsc timers around the encoder phases (rgb.zig prints them).
p=''+SRC+'/webp/encode.zig'; s=open(p).read()
s=s.replace('const entropy = @import("encode_entropy.zig");','''const entropy = @import("encode_entropy.zig");
pub var tsc: [12]u64 = @splat(0);
inline fn rd() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}''')
def rep(a,b):
    global s
    assert a in s, a
    s=s.replace(a,b,1)
import re
m=re.search(r"( *)const candidates = rankModes\(argb[^\n]*\n", s)
s=s[:m.start()]+m.group(1)+"const t0 = rd();\n"+m.group(0)+m.group(1)+"tsc[0] += rd() - t0;\n"+s[m.end():]
rep("    const matches = wk.slice(u32, l.matches, n);\n    st.step_count = 0;\n","    const matches = wk.slice(u32, l.matches, n);\n    st.step_count = 0;\n    const tb = rd();\n")
a="    lz77.findMatches(main_px, cur_w, plan.lz, wk.chain(l), matches[0..main_px.len]);\n"
rep(a, "    tsc[6] += rd() - tb;\n    var t1 = rd();\n"+a+"    tsc[1] += rd() - t1;\n    t1 = rd();\n")
a="    lz77.applyCache(main_px, tokens_all[0..first], cache_bits, cache);\n"
rep(a, a+"    tsc[2] += rd() - t1;\n    t1 = rd();\n")
rep("    st.main = .{\n", "    tsc[3] += rd() - t1;\n    t1 = rd();\n    st.main = .{\n")
rep("    chooseGroups(st, wk, l, plan, green_size, meta);\n}", "    chooseGroups(st, wk, l, plan, green_size, meta);\n    tsc[4] += rd() - t1;\n}")
rep("    const bits = st.bits(s);\n", "    const t5 = rd();\n    const bits = st.bits(s);\n")
rep("    if (vp8l_len & 1 != 0) try w.writeByte(0);\n", "    tsc[5] += rd() - t5;\n    if (vp8l_len & 1 != 0) try w.writeByte(0);\n")
rep("        source.fill(argb);\n        var alpha = false;","        const tf = rd();\n        source.fill(argb);\n        tsc[7] += rd() - tf;\n        var alpha = false;")
open(p,'w').write(s)
r=''+SRC+'/webp/root.zig'; rs=open(r).read(); rs+="\npub const enc_internal = encoder;\n"; open(r,'w').write(rs)

s=open(p).read()
a="    const first = lz77.parse(main_px, matches, model, tokens_all);\n"
assert a in s
s=s.replace(a, a+"    tsc[8] += rd() - t1;\n",1)
a=[x for x in ["    const cache_bits = if (plan.cache) chooseCache(main_px, tokens_all[0..first], cache_scratch, cache) else 0;\n","        chooseCache(main_px, tokens_all[0..first], plan.cache, cache_scratch, cache);\n"] if x in s][0]
assert a in s
s=s.replace(a, a+"    tsc[9] += rd() - t1;\n",1)
open(p,'w').write(s)
