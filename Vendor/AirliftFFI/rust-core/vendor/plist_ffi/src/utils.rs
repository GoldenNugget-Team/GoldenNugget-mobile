// Jackson Coxson

use libc::size_t;
use plist::Value;
use std::ffi::{CStr, CString, c_char, c_void};

use crate::{NodeType, PlistWrapper, plist_t};

#[repr(C)]
pub enum PathElem {
    Key(*const c_char),
    Index(u32),
}

/// # Safety
/// Start praying
#[unsafe(no_mangle)]
#[cfg(feature = "danger")]
pub unsafe extern "C" fn plist_access_path_shim(
    plist: plist_t,
    length: u32,
    path: *const *const c_void,
) -> plist_t {
    if plist.is_null() || path.is_null() {
        return std::ptr::null_mut();
    }

    let current = unsafe { &mut *plist };

    for i in 0..length {
        let arg = unsafe { *path.add(i as usize) };

        match current.borrow_self() {
            Value::Dictionary(d) => {
                let key = arg as *const c_char;
                if key.is_null() {
                    return std::ptr::null_mut();
                }
                let key_str = match unsafe { std::ffi::CStr::from_ptr(key).to_str() } {
                    Ok(s) => s,
                    Err(_) => return std::ptr::null_mut(),
                };
                let Some(val) = d.get_mut(key_str) else {
                    return std::ptr::null_mut();
                };
                let mut new = PlistWrapper {
                    node: NodeType::Child {
                        node: val as *mut _,
                        parent: current.borrow_self() as *mut _,
                        index: u32::MAX,
                        key: Some(key_str.to_string()),
                    },
                    children_wrappers: Vec::new(),
                };
                current
                    .children_wrappers
                    .push(&mut new as *mut PlistWrapper);
            }
            Value::Array(a) => {
                let index = unsafe { *(arg as *const u32) };
                let Some(val) = a.get_mut(index as usize) else {
                    return std::ptr::null_mut();
                };
                let mut new = PlistWrapper {
                    node: NodeType::Child {
                        node: val as *mut _,
                        parent: current.borrow_self() as *mut _,
                        index,
                        key: None,
                    },
                    children_wrappers: Vec::new(),
                };
                current
                    .children_wrappers
                    .push(&mut new as *mut PlistWrapper);
            }
            _ => return std::ptr::null_mut(),
        }
    }

    current as *mut _
}

/// This function is extra silly and quirky and returns a char instead of an int for a bool
/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_compare_node_value(node_l: plist_t, node_r: plist_t) -> c_char {
    let l = unsafe { &mut *node_l }.borrow_self();
    let r = unsafe { &mut *node_r }.borrow_self();
    (l == r) as c_char
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_bool_val_is_true(boolnode: plist_t) -> i8 {
    let node = unsafe { &mut *boolnode }.borrow_self();
    if let Value::Boolean(b) = node {
        if *b { 1 } else { 0 }
    } else {
        0
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_int_val_is_negative(intnode: plist_t) -> i8 {
    let node = unsafe { &mut *intnode }.borrow_self();
    if let Value::Integer(i) = node {
        if *i < 0.into() { 1 } else { 0 }
    } else {
        0
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_int_val_compare(intnode: plist_t, cmpval: i64) -> i8 {
    let node = unsafe { &mut *intnode }.borrow_self();
    if let Value::Integer(i) = node {
        let cmpval = cmpval.into();
        if *i < cmpval {
            -1
        } else if *i > cmpval {
            1
        } else {
            0
        }
    } else {
        -1
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_uint_val_compare(uintnode: plist_t, cmpval: u64) -> i8 {
    let node = unsafe { &mut *uintnode }.borrow_self();
    if let Value::Integer(i) = node {
        let cmpval = cmpval.into();
        if *i < cmpval {
            -1
        } else if *i > cmpval {
            1
        } else {
            0
        }
    } else {
        -1
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_uid_val_compare(uidtnode: plist_t, cmpval: u64) -> i8 {
    let node = unsafe { &mut *uidtnode }.borrow_self();
    if let Value::Uid(i) = node {
        let i = i.get();
        if i < cmpval {
            -1
        } else if i > cmpval {
            1
        } else {
            0
        }
    } else {
        -1
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_real_val_compare(realnode: plist_t, cmpval: f64) -> i8 {
    let node = unsafe { &mut *realnode }.borrow_self();
    if let Value::Real(i) = node {
        if *i < cmpval {
            -1
        } else if *i > cmpval {
            1
        } else {
            0
        }
    } else {
        -1
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_date_val_compare(datenode: plist_t, cmpval: i64) -> i8 {
    let node = unsafe { &mut *datenode }.borrow_self();
    if let Value::Date(i) = node {
        let i: std::time::SystemTime = (*i).into();
        let i = i.duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
        if i < cmpval {
            -1
        } else if i > cmpval {
            1
        } else {
            0
        }
    } else {
        -1
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_string_val_compare(strnode: plist_t, cmpval: *const c_char) -> i8 {
    let node = unsafe { &mut *strnode }.borrow_self();
    let cmpval = unsafe { CStr::from_ptr(cmpval) }
        .to_str()
        .unwrap()
        .to_string();

    if let Value::String(i) = node {
        if *i < cmpval {
            -1
        } else if *i > cmpval {
            1
        } else {
            0
        }
    } else {
        -1
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_string_val_compare_with_size(
    strnode: plist_t,
    cmpval: *const c_char,
    n: size_t,
) -> i8 {
    let node = unsafe { &mut *strnode }.borrow_self();
    let cmpval = unsafe { CStr::from_ptr(cmpval) }
        .to_str()
        .unwrap()
        .to_string();

    if let Value::String(i) = node {
        let i = &i[..n];
        let cmpval = &cmpval[..n];
        if i < cmpval {
            -1
        } else if i > cmpval {
            1
        } else {
            0
        }
    } else {
        -1
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_string_val_contains(strnode: plist_t, substr: *const c_char) -> i8 {
    let node = unsafe { &mut *strnode }.borrow_self();
    let substr = unsafe { CStr::from_ptr(substr) }.to_str().unwrap();

    if let Value::String(i) = node {
        if i.contains(substr) { 1 } else { 0 }
    } else {
        0
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_key_val_compare(keynode: plist_t, cmpval: *const c_char) -> i8 {
    unsafe { plist_string_val_compare(keynode, cmpval) }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_key_val_compare_with_size(
    keynode: plist_t,
    cmpval: *const c_char,
    n: size_t,
) -> i8 {
    unsafe { plist_string_val_compare_with_size(keynode, cmpval, n) }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_key_val_contains(keynode: plist_t, substr: *const c_char) -> i8 {
    unsafe { plist_string_val_contains(keynode, substr) }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_data_val_compare(
    datanode: plist_t,
    cmpval: *const u8,
    n: size_t,
) -> i8 {
    let node = unsafe { &mut *datanode }.borrow_self();
    let cmpval = unsafe { std::slice::from_raw_parts(cmpval, n) };

    if let Value::Data(i) = node {
        if &i[..] > cmpval { 1 } else { 0 }
    } else {
        0
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_data_val_compare_with_size(
    datanode: plist_t,
    cmpval: *const u8,
    n: size_t,
) -> i8 {
    let node = unsafe { &mut *datanode }.borrow_self();
    let cmpval = unsafe { std::slice::from_raw_parts(cmpval, n) };

    if let Value::Data(i) = node {
        if &i[..n] > cmpval { 1 } else { 0 }
    } else {
        0
    }
}

// https://stackoverflow.com/questions/47043167/does-rust-contain-a-way-to-directly-check-whether-or-not-one-vector-is-a-substr
fn is_sub<T: PartialEq>(mut haystack: &[T], needle: &[T]) -> bool {
    if needle.is_empty() {
        return true;
    }
    while !haystack.is_empty() {
        if haystack.starts_with(needle) {
            return true;
        }
        haystack = &haystack[1..];
    }
    false
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_data_val_contains(
    datanode: plist_t,
    cmpval: *const u8,
    n: size_t,
) -> i8 {
    let node = unsafe { &mut *datanode }.borrow_self();
    let cmpval = unsafe { std::slice::from_raw_parts(cmpval, n) };

    if let Value::Data(i) = node {
        if is_sub(i, cmpval) { 1 } else { 0 }
    } else {
        0
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_sort(plist: plist_t) {
    let node = unsafe { &mut *plist }.borrow_self();
    if let Value::Dictionary(d) = node {
        d.sort_keys();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn plist_set_debug(_debug: i8) {
    // no
}

#[unsafe(no_mangle)]
pub extern "C" fn libplist_version() -> *const c_char {
    CString::new("2.0").unwrap().into_raw()
}
