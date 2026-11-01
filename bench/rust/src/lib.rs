//! The Rust arms' operations. Each module lists one format's operations
//! for one crate in `ops`, pairs of an operation name from bench/ops.tsv
//! and a function that writes `out` from `input` and returns the bytes
//! written, or None.

use std::ffi::{c_char, CStr};
use std::sync::OnceLock;

#[cfg(feature = "image-rs")]
mod image_qoi;
#[cfg(feature = "zune")]
mod zune_qoi;

type Op = (&'static CStr, fn(&[u8], &mut [u8]) -> Option<usize>);

extern "C" {
    fn bench_register(
        op: *const c_char,
        f: extern "C" fn(*const u8, usize, *mut u8, usize) -> usize,
    );
}

static OPS: OnceLock<Vec<Op>> = OnceLock::new();

macro_rules! trampolines {
    ($($i:literal)*) => {
        [$({
            extern "C" fn call(input: *const u8, len: usize, out: *mut u8, cap: usize) -> usize {
                let f = OPS.get().expect("bench_init ran")[$i].1;
                // SAFETY: arm.c passes its own buffers of these lengths.
                let (input, out) = unsafe { (std::slice::from_raw_parts(input, len), std::slice::from_raw_parts_mut(out, cap)) };
                f(input, out).unwrap_or(0)
            }
            call as extern "C" fn(*const u8, usize, *mut u8, usize) -> usize
        }),*]
    };
}

#[no_mangle]
pub extern "C" fn bench_init() {
    let tables: &[&[Op]] = &[
        #[cfg(feature = "image-rs")]
        image_qoi::OPS,
        #[cfg(feature = "zune")]
        zune_qoi::OPS,
    ];
    let calls = trampolines!(
        0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31
        32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63
        64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80 81 82 83 84 85 86 87 88 89 90 91 92 93 94 95
        96 97 98 99 100 101 102 103 104 105 106 107 108 109 110 111 112 113 114 115 116 117 118 119 120 121 122 123 124 125 126 127
        128 129 130 131 132 133 134 135 136 137 138 139 140 141 142 143 144 145 146 147 148 149 150 151 152 153 154 155 156 157 158 159
        160 161 162 163 164 165 166 167 168 169 170 171 172 173 174 175 176 177 178 179 180 181 182 183 184 185 186 187 188 189 190 191
        192 193 194 195 196 197 198 199 200 201 202 203 204 205 206 207 208 209 210 211 212 213 214 215 216 217 218 219 220 221 222 223
        224 225 226 227 228 229 230 231 232 233 234 235 236 237 238 239 240 241 242 243 244 245 246 247 248 249 250 251 252 253 254 255
    );
    let ops = OPS.get_or_init(|| tables.iter().flat_map(|t| t.iter().copied()).collect());
    assert!(ops.len() <= calls.len(), "more operations than trampolines");
    for (i, (name, _)) in ops.iter().enumerate() {
        // SAFETY: the name is a static C string, and arm.c keeps only the pointer.
        unsafe { bench_register(name.as_ptr(), calls[i]) };
    }
}
