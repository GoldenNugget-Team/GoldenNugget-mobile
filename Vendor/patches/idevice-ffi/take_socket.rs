    // Inserted into `impl Idevice` in idevice/src/lib.rs (right after `get_socket`)
    // by scripts/build-idevice-ios.sh.
    //
    // Why this exists
    // ---------------
    // `Idevice::get_socket(self) -> Option<Box<dyn ReadWrite>>` consumes the receiver.
    // The `idevice_to_stream` FFI binding has to hand the handle back to the caller
    // (which will `idevice_free` it) when no socket is available, and after a
    // consuming call there is nothing left to hand back -- the caller would
    // double-free.
    //
    // `take_socket` is the same operation without the move, so the error path stays
    // sound. It is additive: `get_socket` and every existing caller are untouched.

    /// Takes the underlying socket out of the connection, leaving the handle
    /// without one.
    ///
    /// Unlike [`Self::get_socket`], this borrows instead of consuming, so a
    /// caller that fails to obtain a socket still owns a valid handle.
    pub fn take_socket(&mut self) -> Option<Box<dyn ReadWrite>> {
        self.socket.take()
    }
