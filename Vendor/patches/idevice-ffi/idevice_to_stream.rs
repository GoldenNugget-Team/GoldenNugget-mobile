// Appended to idevice/ffi/src/lib.rs by scripts/build-idevice-ios.sh
//
// Why this exists
// ---------------
// The shipped Vendor/IDevice.xcframework/ios-arm64/libidevice_ffi.a exports
// `_idevice_to_stream`, and Vendor/IDevice.xcframework/ios-arm64/Headers/idevice.h
// declares it, but upstream idevice v0.1.68 has no such binding. The shipped
// artifact was therefore built from a newer revision than the tag we can pin.
//
// Without this, the archive loses exactly one C-ABI symbol versus the shipped
// one, and Nugget fails to link:
//
//   Vendor/MinimuxerGateway/idevice/IdeviceGateway.swift:1379
//     idevice_to_stream(debugDevice, &stream)     // launchAppPre17, iOS < 17
//
// Semantics (from the header, "This consumes the IdeviceHandle"):
//   * on success the handle is consumed -- the caller must NOT idevice_free it
//     (the Swift caller sets debugDeviceNeedsFree = false right after);
//   * on failure the handle is handed back, so the caller's deferred
//     idevice_free() stays valid instead of double-freeing.
//
// This relies on Idevice::take_socket (see take_socket.rs); `get_socket` takes
// `self` by value and would leave nothing to hand back on the error path.

/// Extracts the underlying stream from an Idevice connection and wraps it in a ReadWriteOpaque
/// stream. This consumes the IdeviceHandle.
///
/// # Arguments
/// * [`idevice`] - The Idevice handle to convert (consumed on success)
/// * [`stream`] - On success, will be set to point to a newly allocated stream handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `idevice` must be a valid pointer to an IdeviceHandle allocated by this library (consumed).
/// `stream` must be a valid pointer to a location where the stream handle will be stored.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn idevice_to_stream(
    idevice: *mut IdeviceHandle,
    stream: *mut *mut ReadWriteOpaque,
) -> *mut IdeviceFfiError {
    if idevice.is_null() || stream.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    // Take ownership: the caller must not free this handle after a successful conversion.
    let mut owned = unsafe { Box::from_raw(idevice) };
    match owned.0.take_socket() {
        Some(rw) => {
            let boxed = Box::new(ReadWriteOpaque { inner: Some(rw) });
            unsafe { *stream = Box::into_raw(boxed) };
            drop(owned); // consumed: the empty handle dies here, the caller does not free it
            null_mut()
        }
        None => {
            // No socket to hand out: give the handle back so the caller's idevice_free()
            // remains valid instead of double-freeing.
            std::mem::forget(owned);
            ffi_err!(IdeviceError::FfiInvalidArg)
        }
    }
}
