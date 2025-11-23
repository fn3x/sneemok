pub const c = @cImport({
    @cDefine("STB_IMAGE_IMPLEMENTATION", "");
    @cDefine("STB_IMAGE_IMPLEMENTATION", "");
    @cDefine("STB_IMAGE_WRITE_IMPLEMENTATION", "");
    @cDefine("STBI_ONLY_PNG", "1");
    @cDefine("STBI_NO_SIMD", "1");
    @cInclude("stb_image_write.h");
    @cInclude("stb_image.h");
    @cInclude("cairo/cairo.h");
    @cInclude("dbus/dbus.h");
});

// Export the global variables that stb_image_write needs
export var stbi_write_png_compression_level: c_int = 8; // 0-9, default 8
export var stbi_write_force_png_filter: c_int = -1;     // -1 = default
