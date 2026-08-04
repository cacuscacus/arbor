//! C ABI for Arbor.
//!
//! SwiftUI (and later other native UIs) call into these symbols.
//! Keep the surface small and stable; evolve carefully.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::Path;
use std::ptr;

use arbor_core::fs::{list_dir, ListOptions};

/// Library version as a null-terminated C string.
#[no_mangle]
pub extern "C" fn arbor_version() -> *const c_char {
    static VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), "\0");
    VERSION.as_ptr() as *const c_char
}

/// List a directory; returns a heap-allocated JSON string, or null on error.
///
/// Caller must free the result with [`arbor_string_free`].
///
/// # Safety
/// `path` must be a valid pointer to a null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn arbor_list_dir(path: *const c_char) -> *mut c_char {
    if path.is_null() {
        return ptr::null_mut();
    }

    let c_str = unsafe { CStr::from_ptr(path) };
    let Ok(path_str) = c_str.to_str() else {
        return ptr::null_mut();
    };

    let entries = match list_dir(Path::new(path_str), ListOptions::default()) {
        Ok(entries) => entries,
        Err(_) => return ptr::null_mut(),
    };

    let Ok(json) = serde_json::to_string(&entries) else {
        return ptr::null_mut();
    };

    match CString::new(json) {
        Ok(c) => c.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Free a string allocated by Arbor FFI functions.
///
/// # Safety
/// `s` must be a pointer previously returned by an Arbor FFI function,
/// or null (no-op).
#[no_mangle]
pub unsafe extern "C" fn arbor_string_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    drop(unsafe { CString::from_raw(s) });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::fs::File;

    #[test]
    fn version_is_non_empty_c_string() {
        let ptr = arbor_version();
        assert!(!ptr.is_null());
        let version = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap();
        assert_eq!(version, env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn list_dir_null_path_returns_null() {
        let ptr = unsafe { arbor_list_dir(ptr::null()) };
        assert!(ptr.is_null());
    }

    #[test]
    fn list_dir_returns_json_and_free_is_safe() {
        let dir = tempfile::tempdir().unwrap();
        File::create(dir.path().join("a.txt")).unwrap();

        let c_path = CString::new(dir.path().to_str().unwrap()).unwrap();
        let ptr = unsafe { arbor_list_dir(c_path.as_ptr()) };
        assert!(!ptr.is_null());

        let json = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap();
        assert!(json.contains("a.txt"));

        unsafe { arbor_string_free(ptr) };
        unsafe { arbor_string_free(ptr::null_mut()) };
    }

    #[test]
    fn list_dir_missing_path_returns_null() {
        let c_path = CString::new("/nonexistent/arbor/ffi/path").unwrap();
        let ptr = unsafe { arbor_list_dir(c_path.as_ptr()) };
        assert!(ptr.is_null());
    }
}
