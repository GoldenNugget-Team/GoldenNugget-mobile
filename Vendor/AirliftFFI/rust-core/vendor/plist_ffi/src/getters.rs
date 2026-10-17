// Jackson Coxson

use std::{
    ffi::{CString, c_char},
    ptr::{null, null_mut},
};

use plist::Value;

use crate::{NodeType, PlistType, PlistWrapper, plist_t};

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_get_parent(node: plist_t) -> plist_t {
    let wrapper = unsafe { &mut *node };
    if let NodeType::Child { parent, node, .. } = wrapper.node {
        // we'll return the parent as a child wrapper
        // might cause issues, who knows
        // for example, if someone uses this parent to add it to another dictionary, it will panic
        // that you tried to move a child
        let parent = unsafe { &mut *parent };
        let p = PlistWrapper {
            node: NodeType::Child {
                node: parent as *mut Value,
                parent: node,
                index: u32::MAX,
                key: None,
            },
            children_wrappers: Vec::new(),
        }
        .into_ptr();
        wrapper.children_wrappers.push(p);
        return p;
    }
    null_mut()
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_get_node_type(node: plist_t) -> PlistType {
    let node = unsafe { &mut *node }.borrow_self();
    match node {
        Value::Array(_) => PlistType::PLIST_ARRAY,
        Value::Dictionary(_) => PlistType::PLIST_DICT,
        Value::Boolean(_) => PlistType::PLIST_BOOLEAN,
        Value::Data(_) => PlistType::PLIST_DATA,
        Value::Date(_) => PlistType::PLIST_DATE,
        Value::Real(_) => PlistType::PLIST_REAL,
        Value::Integer(_) => PlistType::PLIST_INT,
        Value::String(_) => PlistType::PLIST_STRING,
        Value::Uid(_) => PlistType::PLIST_UID,
        _ => PlistType::PLIST_NONE,
    }
}

/// We don't have a key type, so we'll return a string and hope everything is fine
/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_get_key_val(node: plist_t, val: *mut *mut c_char) {
    let node = unsafe { &mut *node }.borrow_self();
    if let Value::String(s) = node {
        let s = CString::new(s.to_string()).unwrap();
        let s = s.into_raw();
        unsafe { *val = s };
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_get_string_val(node: plist_t, val: *mut *mut c_char) {
    let node = unsafe { &mut *node }.borrow_self();
    if let Value::String(s) = node {
        let s = CString::new(s.to_string()).unwrap();
        let s = s.into_raw();
        unsafe { *val = s };
    }
}

/// Since the underlying string isn't necessarily "C safe", we'll cross our fingers
/// and hope that nothing explodes. Can't be that bad, since we're returning the length,right?
/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_get_string_ptr(node: plist_t, length: *mut u64) -> *const c_char {
    if node.is_null() {
        return null();
    }
    let node = unsafe { &mut *node }.borrow_self();
    if let Value::String(s) = node {
        if !length.is_null() {
            unsafe { *length = s.len() as u64 };
        }
        s.as_ptr() as *const c_char
    } else {
        null_mut()
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_get_bool_val(node: plist_t, val: *mut u8) {
    let node = unsafe { &mut *node }.borrow_self();
    if let Value::Boolean(b) = node {
        unsafe { *val = if *b { 1 } else { 0 } };
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_get_uint_val(node: plist_t, val: *mut u64) {
    let node = unsafe { &mut *node }.borrow_self();
    if let Value::Integer(n) = node
        && let Some(u) = n.as_unsigned()
    {
        unsafe { *val = u };
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_get_int_val(node: plist_t, val: *mut i64) {
    let node = unsafe { &mut *node }.borrow_self();
    if let Value::Integer(n) = node
        && let Some(i) = n.as_signed()
    {
        unsafe { *val = i };
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_get_real_val(node: plist_t, val: *mut f64) {
    let node = unsafe { &mut *node }.borrow_self();
    if let Value::Real(r) = node {
        unsafe { *val = *r };
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_get_data_val(node: plist_t, val: *mut *const u8, length: *mut u64) {
    let node = unsafe { &mut *node }.borrow_self();
    if let Value::Data(d) = node {
        // Clone the data and add a null terminator
        let mut data_with_null = d.clone();
        data_with_null.push(0);

        // Convert to boxed slice to heap-allocate
        let boxed: Box<[u8]> = data_with_null.into_boxed_slice();
        let ptr = boxed.as_ptr();

        // Return original length (excluding null terminator)
        unsafe {
            *val = ptr;
            *length = (boxed.len() - 1) as u64;
        }

        // Prevent Rust from freeing it - caller must free
        std::mem::forget(boxed);

        // Plug ears for explosion
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_get_data_ptr(node: plist_t, length: *mut u64) -> *const c_char {
    let node = unsafe { &mut *node }.borrow_self();
    if let Value::Data(d) = node {
        unsafe { *length = d.len() as u64 };
        d.as_ptr() as *const c_char
    } else {
        null_mut()
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_get_unix_date_val(node: plist_t, secs: *mut i64) {
    let node = unsafe { &mut *node }.borrow_self();
    if let Value::Date(d) = node {
        let d = *d;
        let d: std::time::SystemTime = d.into();
        let d = d.duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
        unsafe { *secs = d };
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_get_uid_val(node: plist_t, val: *mut u64) {
    let node = unsafe { &mut *node }.borrow_self();
    if let Value::Uid(u) = node {
        unsafe { *val = u.get() };
    }
}
