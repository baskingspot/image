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
    let calls = trampolines!(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31);
    let ops = OPS.get_or_init(|| tables.iter().flat_map(|t| t.iter().copied()).collect());
    assert!(ops.len() <= calls.len(), "more operations than trampolines");
    for (i, (name, _)) in ops.iter().enumerate() {
        // SAFETY: the name is a static C string, and arm.c keeps only the pointer.
        unsafe { bench_register(name.as_ptr(), calls[i]) };
    }
}
