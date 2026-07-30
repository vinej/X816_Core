//============================================================================
// i2c_open_drain.sv  -  one-bit open-drain driver for an I2C bus pin.
//
// Lets a top-level module attach an additional drive-low signal to an
// inout I2C pin without using a top-level `assign pin = ... ? 1'b0 : 1'bz;`
// alongside another module's inout connection.  Quartus 24.1 Lite has been
// observed to crash on that multi-driver-at-top-level-assign-plus-inout
// pattern; routing every drive source through its own inout port lets
// Quartus combine them uniformly at the IOBUF.
//============================================================================

module i2c_open_drain (
    input  wire drv_low,
    inout  wire pin
);
    assign pin = drv_low ? 1'b0 : 1'bz;
endmodule
