// Jackson Coxson

use std::{
    ffi::{CStr, CString, c_char},
    ptr::null_mut,
};

use plist::Value;

use crate::{NodeType, PlistWrapper, plist_dict_iter, plist_err_t, plist_t};

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_dict_get_size(node: plist_t) -> u32 {
    if let Value::Dictionary(d) = unsafe { &mut *node }.borrow_self() {
        d.len() as u32
    } else {
        0
    }
}

/// Since the free function accepts an iterator, the root objects
/// has to be iterator compatible.
/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_dict_new_iter(_node: plist_t, iter: *mut plist_dict_iter) {
    let p = PlistWrapper::new_iterator(0).into_ptr();
    unsafe { *iter = p };
}

/// # Safety
/// Don't pass a bad plist >:(
/// Use the system allocator or else
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_dict_next_item(
    node: plist_t,
    iter: plist_dict_iter,
    key: *mut *mut c_char,
    item: *mut plist_t,
) {
    let wrapper = unsafe { &mut *node };
    let node = wrapper.borrow_self();

    if let Value::Dictionary(d) = node {
        let iter = unsafe { &mut *iter }.iter_next();

        if iter as usize >= d.len() {
            unsafe { *item = null_mut() };
            return;
        }
        let (p_key, p) = d.iter_mut().nth(iter as usize).unwrap();
        let p_key = p_key.to_string();
        let pc_key = CString::new(p_key.as_str()).unwrap();
        let p = PlistWrapper {
            node: NodeType::Child {
                node: p as *mut Value,
                parent: node as *mut Value,
                index: u32::MAX,
                key: Some(p_key),
            },
            children_wrappers: Vec::new(),
        }
        .into_ptr();
        wrapper.children_wrappers.push(p);
        unsafe {
            *item = p;
            *key = pc_key.into_raw();
        };
    }
}

/// # Safety
/// Don't pass a bad plist >:(
/// Use the system allocator or else
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_dict_get_item_key(node: plist_t, k: *mut *mut c_char) {
    let node = unsafe { &mut *node };
    match &node.node {
        NodeType::Node(_) => {}
        NodeType::Child { key, .. } => {
            if let Some(key) = key {
                let key = CString::new(key.as_str()).unwrap().into_raw();
                unsafe { *k = key };
            }
        }
        NodeType::Iterator(_) => panic!("you passed an iterator as a node"),
    };
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_dict_get_item(node: plist_t, key: *const c_char) -> plist_t {
    let key = unsafe { CStr::from_ptr(key) }.to_str().unwrap();
    let wrapper = unsafe { &mut *node };
    let node = wrapper.borrow_self();
    if let Value::Dictionary(d) = node
        && let Some(v) = d.get_mut(key)
    {
        let p = PlistWrapper {
            node: NodeType::Child {
                node: v as *mut Value,
                parent: node as *mut Value,
                index: u32::MAX,
                key: Some(key.to_string()),
            },
            children_wrappers: Vec::new(),
        }
        .into_ptr();
        wrapper.children_wrappers.push(p);
        return p;
    }
    null_mut()
}

/// We don't have a key plist type in the plist crate
/// We'll just assume the caller knows what they're doing.
/// Blazing fast trust 🚀
/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_dict_item_get_key(node: plist_t) -> plist_t {
    let node = unsafe { &mut *node };
    match &node.node {
        NodeType::Node(_) => null_mut(),
        NodeType::Child { key, .. } => {
            if let Some(key) = key {
                let p = Value::String(key.to_string());
                let p = PlistWrapper::new_node(p);
                p.into_ptr()
            } else {
                null_mut()
            }
        }
        NodeType::Iterator(_) => panic!("you passed an iterator as a node"),
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_dict_set_item(node: plist_t, key: *const c_char, item: plist_t) {
    let wrapper = unsafe { &mut *node };
    let key = unsafe { CStr::from_ptr(key) }.to_str().unwrap();
    let node = wrapper.borrow_self();
    if let Value::Dictionary(d) = node {
        let item = unsafe { *Box::from_raw(item) };
        d.insert(
            key.to_string(),
            item.consume().expect("you tried to steal a child"),
        );
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_dict_remove_item(node: plist_t, key: *const c_char) {
    let wrapper = unsafe { &mut *node };
    let key = unsafe { CStr::from_ptr(key) }.to_str().unwrap();
    let node = wrapper.borrow_self();
    if let Value::Dictionary(d) = node {
        d.remove(key).expect("item doesn't exist");
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_dict_merge(target: *mut plist_t, source: plist_t) {
    let target = unsafe { &mut **target };
    let source = unsafe { *Box::from_raw(source) }
        .consume()
        .expect("you tried to steal a child");
    let node = target.borrow_self();

    if let Value::Dictionary(d_target) = node
        && let Value::Dictionary(d_source) = source
    {
        d_target.extend(d_source);
    }

    // no need to change the pointer since we modified the target in-memory
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_dict_get_bool(dict: plist_t, key: *const c_char) -> u8 {
    let node = unsafe { &mut *dict }.borrow_self();
    let key = unsafe { CStr::from_ptr(key) }.to_str().unwrap();

    if let Value::Dictionary(d) = node {
        match internal_get_bool(d, key) {
            Some(true) => 1,
            Some(false) => 0,
            None => 0,
        }
    } else {
        0
    }
}

fn internal_get_bool(d: &mut plist::Dictionary, key: &str) -> Option<bool> {
    /* The value node can be of type #PLIST_BOOLEAN, but also
     * #PLIST_STRING (either 'true' or 'false'),
     * #PLIST_INT with a numerical value of 0 or >= 1,
     * or #PLIST_DATA with a single byte with a value of 0 or >= 1.
     */
    if let Some(d) = d.get(key) {
        match d {
            Value::Boolean(b) => Some(*b),
            Value::Data(d) => {
                if d.len() != 1 {
                    return None;
                }
                if d[0] < 1 { Some(false) } else { Some(true) }
            }
            Value::Integer(i) => {
                if let Some(i) = i.as_signed() {
                    if i < 1 { Some(false) } else { Some(true) }
                } else if let Some(i) = i.as_unsigned() {
                    if i < 1 { Some(false) } else { Some(true) }
                } else {
                    None
                }
            }
            Value::String(s) => match s.to_lowercase().as_str() {
                "true" => Some(true),
                "false" => Some(false),
                _ => None,
            },
            _ => None,
        }
    } else {
        None
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_dict_get_int(dict: plist_t, key: *const c_char) -> i64 {
    let node = unsafe { &mut *dict }.borrow_self();
    let key = unsafe { CStr::from_ptr(key) }.to_str().unwrap();

    if let Value::Dictionary(d) = node {
        internal_get_i64(d, key).unwrap_or_default()
    } else {
        0
    }
}

fn internal_get_i64(d: &mut plist::Dictionary, key: &str) -> Option<i64> {
    // * The value node can be of type #PLIST_INT, but also
    // * #PLIST_STRING with a numerical value as string (decimal or hexadecimal),
    // * or #PLIST_DATA with a size of 1, 2, 4, or 8 bytes in little endian byte order.
    if let Some(d) = d.get(key) {
        match d {
            Value::Data(d) => {
                if d.len() == 1 {
                    Some(d[0] as i64)
                } else if d.len() == 2 {
                    Some(i16::from_le_bytes([d[0], d[1]]) as i64)
                } else if d.len() == 4 {
                    Some(i32::from_le_bytes([d[0], d[1], d[2], d[3]]) as i64)
                } else if d.len() == 8 {
                    Some(i64::from_le_bytes([
                        d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
                    ]))
                } else {
                    None
                }
            }
            Value::Integer(i) => {
                if let Some(i) = i.as_signed() {
                    Some(i)
                } else if let Some(i) = i.as_unsigned() {
                    i64::try_from(i).ok()
                } else {
                    None
                }
            }
            Value::String(s) => {
                if let Ok(s) = s.parse() {
                    Some(s)
                } else {
                    i64::from_str_radix(s, 16).ok()
                }
            }
            _ => None,
        }
    } else {
        None
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_dict_get_uint(dict: plist_t, key: *const c_char) -> u64 {
    let node = unsafe { &mut *dict }.borrow_self();
    let key = unsafe { CStr::from_ptr(key) }.to_str().unwrap();

    if let Value::Dictionary(d) = node {
        internal_get_u64(d, key).unwrap_or_default()
    } else {
        0
    }
}

fn internal_get_u64(d: &mut plist::Dictionary, key: &str) -> Option<u64> {
    // * The value node can be of type #PLIST_INT, but also
    // * #PLIST_STRING with a numerical value as string (decimal or hexadecimal),
    // * or #PLIST_DATA with a size of 1, 2, 4, or 8 bytes in little endian byte order.
    if let Some(d) = d.get(key) {
        match d {
            Value::Data(d) => {
                if d.len() == 1 {
                    Some(d[0] as u64)
                } else if d.len() == 2 {
                    Some(u16::from_le_bytes([d[0], d[1]]) as u64)
                } else if d.len() == 4 {
                    Some(u32::from_le_bytes([d[0], d[1], d[2], d[3]]) as u64)
                } else if d.len() == 8 {
                    Some(u64::from_le_bytes([
                        d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
                    ]))
                } else {
                    None
                }
            }
            Value::Integer(i) => {
                if let Some(i) = i.as_unsigned() {
                    Some(i)
                } else if let Some(i) = i.as_signed() {
                    u64::try_from(i).ok()
                } else {
                    None
                }
            }
            Value::String(s) => {
                if let Ok(s) = s.parse() {
                    Some(s)
                } else {
                    u64::from_str_radix(s, 16).ok()
                }
            }
            _ => None,
        }
    } else {
        None
    }
}

/**
 * Copy a node from *source_dict* to *target_dict*.
 * The node is looked up in *source_dict* with given *key*, unless *alt_source_key*
 * is non-NULL, in which case it is looked up with *alt_source_key*.
 * The entry in *target_dict* is **always** created with *key*.
 *
 * @param target_dict The target dictionary to copy to.
 * @param source_dict The source dictionary to copy from.
 * @param key The key for the node to copy.
 * @param alt_source_key The alternative source key for lookup in *source_dict* or NULL.
 *
 * @result PLIST_ERR_SUCCESS on success or PLIST_ERR_INVALID_ARG if the source dictionary does not contain
 *     any entry with given key or alt_source_key.
 */
/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_dict_copy_item(
    target_plist: plist_t,
    source_plist: plist_t,
    key: *const c_char,
    alt_source_key: *const c_char,
) -> plist_err_t {
    let target_plist = unsafe { &mut *target_plist }.borrow_self();
    let source_plist = unsafe { &mut *source_plist }.borrow_self();
    let insert_key = unsafe { CStr::from_ptr(key) }.to_str().unwrap();
    let lookup_key = if alt_source_key.is_null() {
        insert_key
    } else {
        unsafe { CStr::from_ptr(alt_source_key) }.to_str().unwrap()
    };

    if let Value::Dictionary(d_target) = target_plist
        && let Value::Dictionary(d_source) = source_plist
    {
        if let Some(to_copy) = d_source.get(lookup_key) {
            let to_copy = to_copy.clone();
            d_target.insert(insert_key.to_string(), to_copy);
            plist_err_t::PLIST_ERR_SUCCESS
        } else {
            plist_err_t::PLIST_ERR_INVALID_ARG
        }
    } else {
        plist_err_t::PLIST_ERR_INVALID_ARG
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_dict_copy_bool(
    target_plist: plist_t,
    source_plist: plist_t,
    key: *const c_char,
    alt_source_key: *const c_char,
) -> plist_err_t {
    let lookup_key = if alt_source_key.is_null() {
        key
    } else {
        alt_source_key
    };
    let lookup_key = unsafe { CStr::from_ptr(lookup_key) }.to_str().unwrap();
    let insert_key = unsafe { CStr::from_ptr(key) }.to_str().unwrap();
    let target_plist = unsafe { &mut *target_plist }.borrow_self();
    let source_plist = unsafe { &mut *source_plist }.borrow_self();
    if let Value::Dictionary(d_target) = target_plist
        && let Value::Dictionary(d_source) = source_plist
    {
        match internal_get_bool(d_source, lookup_key) {
            Some(b) => {
                let p = Value::Boolean(b);
                d_target.insert(insert_key.to_string(), p);
                plist_err_t::PLIST_ERR_SUCCESS
            }
            None => plist_err_t::PLIST_ERR_INVALID_ARG,
        }
    } else {
        plist_err_t::PLIST_ERR_INVALID_ARG
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_dict_copy_int(
    target_plist: plist_t,
    source_plist: plist_t,
    key: *const c_char,
    alt_source_key: *const c_char,
) -> plist_err_t {
    let lookup_key = if alt_source_key.is_null() {
        key
    } else {
        alt_source_key
    };
    let lookup_key = unsafe { CStr::from_ptr(lookup_key) }.to_str().unwrap();
    let insert_key = unsafe { CStr::from_ptr(key) }.to_str().unwrap();
    let target_plist = unsafe { &mut *target_plist }.borrow_self();
    let source_plist = unsafe { &mut *source_plist }.borrow_self();
    if let Value::Dictionary(d_target) = target_plist
        && let Value::Dictionary(d_source) = source_plist
    {
        match internal_get_i64(d_source, lookup_key) {
            Some(i) => {
                let p = Value::Integer(i.into());
                d_target.insert(insert_key.to_string(), p);
                plist_err_t::PLIST_ERR_SUCCESS
            }
            None => plist_err_t::PLIST_ERR_INVALID_ARG,
        }
    } else {
        plist_err_t::PLIST_ERR_INVALID_ARG
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_dict_copy_uint(
    target_plist: plist_t,
    source_plist: plist_t,
    key: *const c_char,
    alt_source_key: *const c_char,
) -> plist_err_t {
    let lookup_key = if alt_source_key.is_null() {
        key
    } else {
        alt_source_key
    };
    let lookup_key = unsafe { CStr::from_ptr(lookup_key) }.to_str().unwrap();
    let insert_key = unsafe { CStr::from_ptr(key) }.to_str().unwrap();
    let target_plist = unsafe { &mut *target_plist }.borrow_self();
    let source_plist = unsafe { &mut *source_plist }.borrow_self();
    if let Value::Dictionary(d_target) = target_plist
        && let Value::Dictionary(d_source) = source_plist
    {
        match internal_get_u64(d_source, lookup_key) {
            Some(i) => {
                let p = Value::Integer(i.into());
                d_target.insert(insert_key.to_string(), p);
                plist_err_t::PLIST_ERR_SUCCESS
            }
            None => plist_err_t::PLIST_ERR_INVALID_ARG,
        }
    } else {
        plist_err_t::PLIST_ERR_INVALID_ARG
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_dict_copy_data(
    target_plist: plist_t,
    source_plist: plist_t,
    key: *const c_char,
    alt_source_key: *const c_char,
) -> plist_err_t {
    let lookup_key = if alt_source_key.is_null() {
        key
    } else {
        alt_source_key
    };
    let lookup_key = unsafe { CStr::from_ptr(lookup_key) }.to_str().unwrap();
    let insert_key = unsafe { CStr::from_ptr(key) }.to_str().unwrap();
    let target_plist = unsafe { &mut *target_plist }.borrow_self();
    let source_plist = unsafe { &mut *source_plist }.borrow_self();
    if let Value::Dictionary(d_target) = target_plist
        && let Value::Dictionary(d_source) = source_plist
    {
        if let Some(Value::Data(d)) = d_source.get(lookup_key) {
            let d = Value::Data(d.clone());
            d_target.insert(insert_key.to_string(), d);
            plist_err_t::PLIST_ERR_SUCCESS
        } else {
            plist_err_t::PLIST_ERR_INVALID_ARG
        }
    } else {
        plist_err_t::PLIST_ERR_INVALID_ARG
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_dict_copy_string(
    target_plist: plist_t,
    source_plist: plist_t,
    key: *const c_char,
    alt_source_key: *const c_char,
) -> plist_err_t {
    let lookup_key = if alt_source_key.is_null() {
        key
    } else {
        alt_source_key
    };
    let lookup_key = unsafe { CStr::from_ptr(lookup_key) }.to_str().unwrap();
    let insert_key = unsafe { CStr::from_ptr(key) }.to_str().unwrap();
    let target_plist = unsafe { &mut *target_plist }.borrow_self();
    let source_plist = unsafe { &mut *source_plist }.borrow_self();
    if let Value::Dictionary(d_target) = target_plist
        && let Value::Dictionary(d_source) = source_plist
    {
        if let Some(Value::String(s)) = d_source.get(lookup_key) {
            let d = Value::String(s.clone());
            d_target.insert(insert_key.to_string(), d);
            plist_err_t::PLIST_ERR_SUCCESS
        } else {
            plist_err_t::PLIST_ERR_INVALID_ARG
        }
    } else {
        plist_err_t::PLIST_ERR_INVALID_ARG
    }
}
