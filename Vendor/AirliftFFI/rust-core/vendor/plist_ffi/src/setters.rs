// Jackson Coxson

use std::ffi::{CStr, c_char};

use plist::Value;

use crate::plist_t;

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_set_key_val(node: plist_t, val: *const c_char) {
    let node = unsafe { &mut *node }.borrow_self();
    let val = unsafe { CStr::from_ptr(val) }.to_str().unwrap();
    *node = Value::String(val.to_string());
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_set_string_val(node: plist_t, val: *const c_char) {
    let node = unsafe { &mut *node }.borrow_self();
    let val = unsafe { CStr::from_ptr(val) }.to_str().unwrap();
    *node = Value::String(val.to_string());
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_set_bool_val(node: plist_t, val: u8) {
    let node = unsafe { &mut *node }.borrow_self();
    *node = Value::Boolean(val != 0);
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_set_uint_val(node: plist_t, val: u64) {
    let node = unsafe { &mut *node }.borrow_self();
    *node = Value::Integer(val.into());
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_set_int_val(node: plist_t, val: i64) {
    let node = unsafe { &mut *node }.borrow_self();
    *node = Value::Integer(val.into());
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_set_real_val(node: plist_t, val: f64) {
    let node = unsafe { &mut *node }.borrow_self();
    *node = Value::Real(val);
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_set_data_val(node: plist_t, val: *const u8, length: u64) {
    let node = unsafe { &mut *node }.borrow_self();
    let val = unsafe { std::slice::from_raw_parts(val, length as usize) }.to_vec();
    *node = Value::Data(val);
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_set_unix_date_val(node: plist_t, sec: i64) {
    let node = unsafe { &mut *node }.borrow_self();
    let d = std::time::UNIX_EPOCH + std::time::Duration::from_secs(sec as u64);
    *node = Value::Date(d.into());
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_set_uid_val(node: plist_t, val: u64) {
    let node = unsafe { &mut *node }.borrow_self();
    *node = Value::Uid(plist::Uid::new(val));
}
