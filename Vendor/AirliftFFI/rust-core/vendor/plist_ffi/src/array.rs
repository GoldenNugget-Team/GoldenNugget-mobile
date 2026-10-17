// Jackson Coxson

use plist::Value;
use std::ptr::null_mut;

use crate::{NodeType, PlistWrapper, plist_array_iter, plist_t};

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_array_get_size(node: plist_t) -> u32 {
    let node = unsafe { &mut *node }.borrow_self();
    match node {
        Value::Array(a) => a.len() as u32,
        _ => 0,
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_array_get_item(node: plist_t, n: u32) -> plist_t {
    let wrapper = unsafe { &mut *node };
    let mut node = wrapper.borrow_self();
    match &mut node {
        Value::Array(a) => {
            if n as usize >= a.len() {
                return null_mut();
            }
            let p = a.get_mut(n as usize).unwrap();
            let p = PlistWrapper {
                node: NodeType::Child {
                    node: p as *mut Value,
                    parent: node as *mut Value,
                    index: n,
                    key: None,
                },
                children_wrappers: Vec::new(),
            }
            .into_ptr();
            wrapper.children_wrappers.push(p);
            p
        }
        _ => null_mut(),
    }
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_array_get_item_index(node: plist_t) -> u32 {
    let node = unsafe { &mut *node };
    match node.node {
        NodeType::Node(_) => u32::MAX,
        NodeType::Child { index, .. } => index,
        NodeType::Iterator(_) => panic!("you passed an iterator as a node"),
    }
}

/// # Safety
/// Don't pass a bad plist >:(
/// Will assert if n > len or if item is a child
/// Don't move a child
/// The array owns the item now, don't use it
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_array_set_item(node: plist_t, item: plist_t, n: u32) {
    let item = unsafe { Box::from_raw(item) };
    let item = match item.consume() {
        Some(i) => i,
        None => {
            panic!("You just tried to move a child into an array");
        }
    };
    let node = unsafe { &mut *node }.borrow_self();
    if let Value::Array(a) = node {
        a[n as usize] = item;
    }
}

/// # Safety
/// Don't pass a bad plist >:(
/// Don't move a child
/// The array owns the item now, don't use it
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_array_append_item(node: plist_t, item: plist_t) {
    let item = unsafe { Box::from_raw(item) };
    let item = match item.consume() {
        Some(i) => i,
        None => {
            panic!("You just tried to move a child into an array");
        }
    };
    let node = unsafe { &mut *node }.borrow_self();
    if let Value::Array(a) = node {
        a.push(item);
    }
}

/// # Safety
/// Don't pass a bad plist >:(
/// Will assert if n > len or if item is a child
/// Don't move a child
/// The array owns the item now, don't use it
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_array_insert_item(node: plist_t, item: plist_t, n: u32) {
    let item = unsafe { Box::from_raw(item) };
    let item = match item.consume() {
        Some(i) => i,
        None => {
            panic!("You just tried to move a child into an array");
        }
    };
    let node = unsafe { &mut *node }.borrow_self();
    if let Value::Array(a) = node {
        a.insert(n as usize, item);
    }
}

/// # Safety
/// Don't pass a bad plist >:(
/// Will assert if n > len
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_array_remove_item(node: plist_t, n: u32) {
    let node = unsafe { &mut *node }.borrow_self();
    if let Value::Array(a) = node {
        let _ = a.remove(n as usize);
    }
}

/// Remove self from the parent array
/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_array_item_remove(node: plist_t) {
    let node = unsafe { &mut *node };
    if let NodeType::Child { parent, index, .. } = &mut node.node {
        let parent = unsafe { &mut **parent };
        if let Value::Array(parent) = parent {
            parent.remove(*index as usize);
        }
    }
}

/// Since the free function accepts an iterator, the root objects
/// has to be iterator compatible.
/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_array_new_iter(_node: plist_t, iter: *mut plist_array_iter) {
    let p = PlistWrapper::new_iterator(0).into_ptr();
    unsafe { *iter = p };
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_array_next_item(
    node: plist_t,
    iter: plist_array_iter,
    item: *mut plist_t,
) {
    let wrapper = unsafe { &mut *node };
    let node = wrapper.borrow_self();

    if let Value::Array(a) = node {
        let iter = unsafe { &mut *iter }.iter_next();

        if iter as usize >= a.len() {
            unsafe { *item = null_mut() };
            return;
        }
        let p = a.get_mut(iter as usize).unwrap();
        let p = PlistWrapper {
            node: NodeType::Child {
                node: p as *mut Value,
                parent: node as *mut Value,
                index: iter,
                key: None,
            },
            children_wrappers: Vec::new(),
        }
        .into_ptr();
        wrapper.children_wrappers.push(p);
        unsafe { *item = p };
    }
}
