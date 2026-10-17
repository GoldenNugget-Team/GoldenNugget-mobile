// Jackson Coxson

use std::ffi::{CStr, c_char, c_void};

use plist::Value;

use crate::{PLIST_OPT_INDENT, PlistFormat, PlistWrapper, PlistWriteOptions, plist_err_t, plist_t};

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_to_xml(
    node: plist_t,
    plist_xml: *mut *mut c_char,
    length: *mut u32,
) -> plist_err_t {
    let node = unsafe { &mut *node }.borrow_self();

    let buf = Vec::new();
    let mut writer = std::io::BufWriter::new(buf);
    plist::to_writer_xml(&mut writer, node).unwrap();
    let mut xml = writer.into_inner().unwrap();
    xml.push(0);
    let mut boxed = xml.into_boxed_slice();

    let ptr = boxed.as_mut_ptr();

    // Return original length (excluding null terminator)
    unsafe {
        *plist_xml = ptr as *mut c_char;
        *length = (boxed.len() - 1) as u32;
    }

    // Prevent Rust from freeing it — caller must free
    std::mem::forget(boxed);
    plist_err_t::PLIST_ERR_SUCCESS
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_to_bin(
    node: plist_t,
    plist_bin: *mut *mut c_char,
    length: *mut u32,
) -> plist_err_t {
    let node = unsafe { &mut *node }.borrow_self();

    let buf = Vec::new();
    let mut writer = std::io::BufWriter::new(buf);
    plist::to_writer_binary(&mut writer, node).unwrap();
    let mut xml = writer.into_inner().unwrap();
    xml.push(0);
    let mut boxed = xml.into_boxed_slice();

    let ptr = boxed.as_mut_ptr();

    // Return original length (excluding null terminator)
    unsafe {
        *plist_bin = ptr as *mut c_char;
        *length = (boxed.len() - 1) as u32;
    }

    // Prevent Rust from freeing it - caller must free
    std::mem::forget(boxed);
    plist_err_t::PLIST_ERR_SUCCESS
}

/// # Safety
/// Don't pass a bad plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_to_json(
    node: plist_t,
    plist_json: *mut *mut c_char,
    length: *mut u32,
    prettify: i32,
) -> plist_err_t {
    let node = unsafe { &mut *node }.borrow_self();

    let mut s = if prettify > 0 {
        serde_json::to_string_pretty(node)
    } else {
        serde_json::to_string(node)
    }
    .unwrap()
    .as_bytes()
    .to_vec();

    s.push(0);
    let mut boxed = s.into_boxed_slice();

    let ptr = boxed.as_mut_ptr();

    // Return original length (excluding null terminator)
    unsafe {
        *plist_json = ptr as *mut c_char;
        *length = (boxed.len() - 1) as u32;
    }

    // Prevent Rust from freeing it - caller must free
    std::mem::forget(boxed);
    plist_err_t::PLIST_ERR_SUCCESS
}

/// There is hardly any information on this format. Hopefully this isn't used anywhere.
/// # Safety
/// don't use this
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_to_openstep(
    _node: plist_t,
    _plist_json: *mut *mut c_char,
    _length: *mut u32,
    _prettify: i32,
) -> plist_err_t {
    unimplemented!()
}

/// # Safety
/// Don't be stupid
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_from_xml(
    plist_xml: *const c_char,
    length: u32,
    plist: *mut plist_t,
) -> plist_err_t {
    let data = unsafe { std::slice::from_raw_parts(plist_xml as *const u8, length as usize) };
    if let Ok(data) = plist::from_bytes(data) {
        let p = PlistWrapper::new_node(data).into_ptr();
        unsafe { *plist = p };
        plist_err_t::PLIST_ERR_SUCCESS
    } else {
        plist_err_t::PLIST_ERR_PARSE
    }
}

/// # Safety
/// Don't be stupid
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_from_bin(
    plist_bin: *const c_char,
    length: u32,
    plist: *mut plist_t,
) -> plist_err_t {
    let data = unsafe { std::slice::from_raw_parts(plist_bin as *const u8, length as usize) };
    if let Ok(data) = plist::from_bytes(data) {
        let p = PlistWrapper::new_node(data).into_ptr();
        unsafe { *plist = p };
        plist_err_t::PLIST_ERR_SUCCESS
    } else {
        plist_err_t::PLIST_ERR_PARSE
    }
}

/// # Safety
/// Don't be stupid
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_from_json(
    plist_json: *const c_char,
    length: u32,
    plist: *mut plist_t,
) -> plist_err_t {
    let data = unsafe { std::slice::from_raw_parts(plist_json as *const u8, length as usize) };
    if let Ok(data) = serde_json::from_slice(data) {
        let p = PlistWrapper::new_node(data).into_ptr();
        unsafe { *plist = p };
        plist_err_t::PLIST_ERR_SUCCESS
    } else {
        plist_err_t::PLIST_ERR_PARSE
    }
}

/// # Safety
/// Don't be stupid
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_from_memory(
    plist_data: *const c_char,
    length: u32,
    plist: *mut plist_t,
    plist_format: *mut PlistFormat,
) -> plist_err_t {
    unsafe {
        if plist_from_xml(plist_data, length, plist) == plist_err_t::PLIST_ERR_SUCCESS {
            if !plist_format.is_null() {
                *plist_format = PlistFormat::PLIST_FORMAT_XML; // this can also be true for binary
            }
            return plist_err_t::PLIST_ERR_SUCCESS;
        }
        if plist_from_json(plist_data, length, plist) == plist_err_t::PLIST_ERR_SUCCESS {
            if !plist_format.is_null() {
                *plist_format = PlistFormat::PLIST_FORMAT_JSON;
            }
            return plist_err_t::PLIST_ERR_SUCCESS;
        }
        plist_err_t::PLIST_ERR_PARSE
    }
}

/// # Safety
/// Don't be stupid
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_read_from_file(
    filename: *const c_char,
    plist: *mut plist_t,
    plist_format: *mut PlistFormat,
) -> plist_err_t {
    let filename = unsafe { CStr::from_ptr(filename) }.to_str().unwrap();
    let f = match std::fs::read(filename) {
        Ok(f) => f,
        Err(_) => return plist_err_t::PLIST_ERR_IO,
    };

    unsafe {
        plist_from_memory(
            f.as_ptr() as *const c_char,
            f.len() as u32,
            plist,
            plist_format,
        )
    }
}

/// # Safety
/// Don't be stupid
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_write_to_string(
    plist: plist_t,
    output: *mut *mut c_char,
    length: *mut u32,
    format: PlistFormat,
    options: PlistWriteOptions,
) -> plist_err_t {
    let node = unsafe { &mut *plist }.borrow_self();

    let mut data = match format {
        PlistFormat::PLIST_FORMAT_XML => {
            let buf = Vec::new();
            let mut writer = std::io::BufWriter::new(buf);
            plist::to_writer_xml(&mut writer, node).unwrap();
            writer.into_inner().unwrap()
        }
        PlistFormat::PLIST_FORMAT_BINARY => {
            let buf = Vec::new();
            let mut writer = std::io::BufWriter::new(buf);
            plist::to_writer_binary(&mut writer, node).unwrap();
            writer.into_inner().unwrap()
        }
        PlistFormat::PLIST_FORMAT_JSON => {
            if options & PLIST_OPT_INDENT != 0 {
                serde_json::to_vec_pretty(node).unwrap()
            } else {
                serde_json::to_vec(node).unwrap()
            }
        }
        _ => return plist_err_t::PLIST_ERR_INVALID_ARG,
    };
    data.push(0);
    let mut boxed = data.into_boxed_slice();

    let ptr = boxed.as_mut_ptr();

    // Return original length (excluding null terminator)
    unsafe {
        *output = ptr as *mut c_char;
        *length = (boxed.len() - 1) as u32;
    }

    // Prevent Rust from freeing it - caller must free
    std::mem::forget(boxed);
    plist_err_t::PLIST_ERR_SUCCESS
}

/// # Safety
/// Don't be stupid
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_write_to_stream(
    plist: plist_t,
    stream: *mut libc::FILE,
    format: PlistFormat,
    options: PlistWriteOptions,
) -> plist_err_t {
    if plist.is_null() || stream.is_null() {
        return plist_err_t::PLIST_ERR_INVALID_ARG;
    }

    let wrapper = unsafe { &mut *plist };
    let value = wrapper.borrow_self();

    let mut buf = Vec::new();
    let result = match format {
        PlistFormat::PLIST_FORMAT_JSON => {
            buf = if options & PLIST_OPT_INDENT != 0 {
                serde_json::to_vec_pretty(value)
            } else {
                serde_json::to_vec(value)
            }
            .unwrap();
            Ok(())
        }
        PlistFormat::PLIST_FORMAT_XML => plist::to_writer_xml(&mut buf, value),
        PlistFormat::PLIST_FORMAT_BINARY => plist::to_writer_binary(&mut buf, value),
        _ => return plist_err_t::PLIST_ERR_INVALID_ARG,
    };

    if result.is_err() {
        return plist_err_t::PLIST_ERR_INVALID_ARG;
    }

    if unsafe { !write_to_stream(stream, &buf) } {
        return plist_err_t::PLIST_ERR_INVALID_ARG;
    }

    unsafe { libc::fflush(stream) };
    plist_err_t::PLIST_ERR_SUCCESS
}

unsafe fn write_to_stream(stream: *mut libc::FILE, buf: &[u8]) -> bool {
    let written = unsafe { libc::fwrite(buf.as_ptr() as *const c_void, 1, buf.len(), stream) };
    written == buf.len()
}

/// # Safety
/// Don't be stupid
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_write_to_file(
    plist: plist_t,
    filename: *const c_char,
    format: PlistFormat,
    options: PlistWriteOptions,
) -> plist_err_t {
    let value = unsafe { &mut *plist }.borrow_self();
    let filename = unsafe { CStr::from_ptr(filename) }.to_str().unwrap();
    let mut buf = Vec::new();
    let result = match format {
        PlistFormat::PLIST_FORMAT_JSON => {
            buf = if options & PLIST_OPT_INDENT != 0 {
                serde_json::to_vec_pretty(value)
            } else {
                serde_json::to_vec(value)
            }
            .unwrap();
            Ok(())
        }
        PlistFormat::PLIST_FORMAT_XML => plist::to_writer_xml(&mut buf, value),
        PlistFormat::PLIST_FORMAT_BINARY => plist::to_writer_binary(&mut buf, value),
        _ => return plist_err_t::PLIST_ERR_INVALID_ARG,
    };
    if result.is_err() {
        return plist_err_t::PLIST_ERR_INVALID_ARG;
    }

    if std::fs::write(filename, buf).is_ok() {
        plist_err_t::PLIST_ERR_SUCCESS
    } else {
        plist_err_t::PLIST_ERR_IO
    }
}

/// # Safety
/// Pass a valid plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_print(plist: plist_t) {
    let node = unsafe { &mut *plist }.borrow_self();
    println!("{}", pretty_print_plist(node));
}

/// # Safety
/// Pass a valid plist >:(
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plist_is_binary(plist_data: *const c_char, length: u32) -> u8 {
    let data = unsafe { std::slice::from_raw_parts(plist_data as *const u8, length as usize) };
    if data.is_ascii() { 0 } else { 1 }
}

/////////////////////////
// STOLEN FROM IDEVICE //
/////////////////////////

/// Pretty-prints a PLIST value with indentation
///
/// # Arguments
/// * `p` - The PLIST value to format
///
/// # Returns
/// A formatted string representation
pub fn pretty_print_plist(p: &Value) -> String {
    print_plist(p, 0)
}

/// Pretty-prints a PLIST dictionary with key-value pairs
///
/// # Arguments
/// * `dict` - The dictionary to format
///
/// # Returns
/// A formatted string representation with newlines and indentation
///
/// # Example
/// ```rust
/// let mut dict = plist::Dictionary::new();
/// dict.insert("name".into(), "John".into());
/// dict.insert("age".into(), 30.into());
/// println!("{}", pretty_print_dictionary(&dict));
/// ```
pub fn pretty_print_dictionary(dict: &plist::Dictionary) -> String {
    let items: Vec<String> = dict
        .iter()
        .map(|(k, v)| format!("{}: {}", k, print_plist(v, 2)))
        .collect();
    format!("{{\n{}\n}}", items.join(",\n"))
}

/// Internal recursive function for printing PLIST values with indentation
///
/// # Arguments
/// * `p` - The PLIST value to format
/// * `indentation` - Current indentation level
///
/// # Returns
/// Formatted string representation
fn print_plist(p: &Value, indentation: usize) -> String {
    let indent = " ".repeat(indentation);
    match p {
        Value::Array(vec) => {
            let items: Vec<String> = vec
                .iter()
                .map(|v| {
                    format!(
                        "{}{}",
                        " ".repeat(indentation + 2),
                        print_plist(v, indentation + 2)
                    )
                })
                .collect();
            format!("[\n{}\n{}]", items.join(",\n"), indent)
        }
        Value::Dictionary(dict) => {
            let items: Vec<String> = dict
                .iter()
                .map(|(k, v)| {
                    format!(
                        "{}{}: {}",
                        " ".repeat(indentation + 2),
                        k,
                        print_plist(v, indentation + 2)
                    )
                })
                .collect();
            format!("{{\n{}\n{}}}", items.join(",\n"), indent)
        }
        Value::Boolean(b) => format!("{b}"),
        Value::Data(vec) => {
            let len = vec.len();
            let preview: String = vec
                .iter()
                .take(20)
                .map(|b| format!("{b:02X}"))
                .collect::<Vec<String>>()
                .join(" ");
            if len > 20 {
                format!("Data({preview}... Len: {len})")
            } else {
                format!("Data({preview} Len: {len})")
            }
        }
        Value::Date(date) => format!("Date({})", date.to_xml_format()),
        Value::Real(f) => format!("{f}"),
        Value::Integer(i) => format!("{i}"),
        Value::String(s) => format!("\"{s}\""),
        Value::Uid(_uid) => "Uid(?)".to_string(),
        _ => "Unknown".to_string(),
    }
}
