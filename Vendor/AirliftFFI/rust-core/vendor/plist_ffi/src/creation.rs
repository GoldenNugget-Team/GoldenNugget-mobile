// Jackson Coxson

use plist::{Dictionary, Uid, Value};
use std::ffi::{CStr, CString, c_char};

use crate::plist_t;

/// Creates a new dictionary plist
#[unsafe(no_mangle)]
pub extern "C" fn plist_new_dict() -> plist_t {
    let p = Value::Dictionary(Dictionary::new()).into();
    let p = Box::new(p);
    Box::into_raw(p)
}

/// Creates a new array plist
#[unsafe(no_mangle)]
pub extern "C" fn plist_new_array() -> plist_t {
    let p = Value::Array(Vec::new()).into();
    let p = Box::new(p);
    Box::into_raw(p)
}

/// # Safety
/// Don't pass a bad string, libplist doesn't check the string
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_new_string(val: *const c_char) -> plist_t {
    let s = unsafe { CStr::from_ptr(val) }.to_str().unwrap();
    let p = Value::String(s.to_string()).into();
    let p = Box::new(p);
    Box::into_raw(p)
}

#[unsafe(no_mangle)]
pub extern "C" fn plist_new_bool(val: u8) -> plist_t {
    let p = Value::Boolean(val != 0).into();
    let p = Box::new(p);
    Box::into_raw(p)
}

#[unsafe(no_mangle)]
pub extern "C" fn plist_new_uint(val: u64) -> plist_t {
    let p = Value::Integer(val.into()).into();
    let p = Box::new(p);
    Box::into_raw(p)
}

#[unsafe(no_mangle)]
pub extern "C" fn plist_new_int(val: i64) -> plist_t {
    let p = Value::Integer(val.into()).into();
    let p = Box::new(p);
    Box::into_raw(p)
}

#[unsafe(no_mangle)]
pub extern "C" fn plist_new_real(val: f64) -> plist_t {
    let p = Value::Real(val).into();
    let p = Box::new(p);
    Box::into_raw(p)
}

/// # Safety
/// Rust owns your data now. Don't pass a bad pointer >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_new_data(val: *const u8, length: u64) -> plist_t {
    let slice = unsafe { std::slice::from_raw_parts(val, length as usize) }.to_vec();
    let p = Value::Data(slice).into();
    let p = Box::new(p);
    Box::into_raw(p)
}

/// Don't pass a negative number >:(
#[unsafe(no_mangle)]
pub extern "C" fn plist_new_unix_date(sec: i64) -> plist_t {
    let s = std::time::UNIX_EPOCH + std::time::Duration::from_secs(sec as u64);
    let p = Value::Date(s.into()).into();
    let p = Box::new(p);
    Box::into_raw(p)
}

#[unsafe(no_mangle)]
pub extern "C" fn plist_new_uid(val: u64) -> plist_t {
    let p = Value::Uid(Uid::new(val)).into();
    let p = Box::new(p);
    Box::into_raw(p)
}

/// So there's no null plist type in Rust, so we'll just have an empty data :shrug:
#[unsafe(no_mangle)]
pub extern "C" fn plist_new_null() -> plist_t {
    let p = Value::Data(Vec::new()).into();
    let p = Box::new(p);
    Box::into_raw(p)
}

/// # Safety
/// Needs to be allocated by this library
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_free(plist: plist_t) {
    if plist.is_null() {
        return;
    }
    let _parent = unsafe { Box::from_raw(plist) };
    // The drop function will take care of the children
}

/// # Safety
/// Needs to be allocated by this library
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_copy(node: plist_t) -> plist_t {
    let p = unsafe { &*node };
    let p = Box::new(p.clone());
    Box::into_raw(p)
}

/// # Safety
/// Needs to be allocated by this library
/// I sure hope nothing bad happens
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_mem_free(data: *mut c_char) {
    let _ = unsafe { CString::from_raw(data) };
}
