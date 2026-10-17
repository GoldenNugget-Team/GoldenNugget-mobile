// Jackson Coxson

use plist::Value;

pub mod array;
pub mod creation;
pub mod dict;
pub mod getters;
pub mod import;
pub mod setters;
pub mod utils;

#[allow(non_camel_case_types)]
#[repr(C)]
pub enum PlistType {
    PLIST_NONE = -1,
    PLIST_BOOLEAN,
    PLIST_INT,
    PLIST_REAL,
    PLIST_STRING,
    PLIST_ARRAY,
    PLIST_DICT,
    PLIST_DATE,
    PLIST_DATA,
    PLIST_KEY,
    PLIST_UID,
    PLIST_NULL,
}

#[allow(non_camel_case_types)]
#[repr(C)]
#[derive(PartialEq)]
pub enum PlistErr {
    PLIST_ERR_SUCCESS = 0,
    PLIST_ERR_INVALID_ARG = -1,
    PLIST_ERR_FORMAT = -2,
    PLIST_ERR_PARSE = -3,
    PLIST_ERR_NO_MEM = -4,
    PLIST_ERR_IO = -5,
    PLIST_ERR_UNKNOWN = -255,
}

#[allow(non_camel_case_types)]
#[repr(C)]
pub enum PlistFormat {
    PLIST_FORMAT_NONE = 0,
    PLIST_FORMAT_XML = 1,
    PLIST_FORMAT_BINARY = 2,
    PLIST_FORMAT_JSON = 3,
    PLIST_FORMAT_OSTEP = 4,
    PLIST_FORMAT_PRINT = 10,
    PLIST_FORMAT_LIMD = 11,
    PLIST_FORMAT_PLUTIL = 12,
}

pub type PlistWriteOptions = u32;
pub const PLIST_OPT_NONE: PlistWriteOptions = 0;
pub const PLIST_OPT_COMPACT: PlistWriteOptions = 1 << 0;
pub const PLIST_OPT_PARTIAL_DATA: PlistWriteOptions = 1 << 1;
pub const PLIST_OPT_NO_NEWLINE: PlistWriteOptions = 1 << 2;
pub const PLIST_OPT_INDENT: PlistWriteOptions = 1 << 3;

#[allow(non_camel_case_types)]
pub type plist_t = *mut PlistWrapper;
#[allow(non_camel_case_types)]
type plist_array_iter = *mut PlistWrapper;
#[allow(non_camel_case_types)]
type plist_dict_iter = *mut PlistWrapper;
#[allow(non_camel_case_types)]
type plist_err_t = PlistErr;

pub struct PlistWrapper {
    node: NodeType,
    children_wrappers: Vec<*mut PlistWrapper>,
}

pub enum NodeType {
    Node(Value),
    Child {
        node: *mut Value,
        parent: *mut Value,
        index: u32,          // for arrays
        key: Option<String>, // for dictionaries
    },
    Iterator(u32),
}

/// An FFI, libplist, compatible wrapper for plist's Value.
impl PlistWrapper {
    /// Gets a reference to the Value from the wrapper
    /// Note that you cannot retrieve the actual value,
    /// as the value might be a child of another wrapper.
    pub fn borrow_self(&mut self) -> &mut Value {
        match &mut self.node {
            NodeType::Node(value) => value,
            NodeType::Child { node, .. } => unsafe { &mut **node },
            NodeType::Iterator(_) => panic!("you passed an iterator as a node"),
        }
    }
    pub(crate) fn consume(mut self) -> Option<Value> {
        // Put something harmless back so Drop can still run.
        let node = std::mem::replace(&mut self.node, NodeType::Iterator(0));

        match node {
            NodeType::Node(v) => Some(v),
            NodeType::Child { .. } => None,
            NodeType::Iterator(_) => panic!("you passed an iterator as a node"),
        }
    }
    pub(crate) fn iter_next(&mut self) -> u32 {
        match &mut self.node {
            NodeType::Iterator(i) => {
                let to_return = *i;
                *i += 1;
                to_return
            }
            _ => panic!("you passed a node as an interator"),
        }
    }
    pub fn new_node(v: Value) -> Self {
        Self {
            node: NodeType::Node(v),
            children_wrappers: Vec::new(),
        }
    }
    pub(crate) fn new_iterator(i: u32) -> Self {
        Self {
            node: NodeType::Iterator(i),
            children_wrappers: Vec::new(),
        }
    }
    pub fn into_ptr(self) -> plist_t {
        let p = Box::new(self);
        Box::into_raw(p)
    }
}

impl From<Value> for PlistWrapper {
    fn from(value: Value) -> Self {
        Self::new_node(value)
    }
}

impl Clone for PlistWrapper {
    fn clone(&self) -> Self {
        match &self.node {
            NodeType::Node(value) => PlistWrapper::new_node(value.clone()),
            NodeType::Child { node, .. } => unsafe {
                let cloned = (**node).clone();
                PlistWrapper::new_node(cloned)
            },
            NodeType::Iterator(i) => PlistWrapper::new_iterator(*i),
        }
    }
}

impl Drop for PlistWrapper {
    fn drop(&mut self) {
        for c in &self.children_wrappers {
            unsafe {
                creation::plist_free(*c);
            }
        }
    }
}
