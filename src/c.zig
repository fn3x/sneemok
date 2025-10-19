pub const c = @cImport({
    @cDefine("STB_IMAGE_IMPLEMENTATION", "");
    @cDefine("STBI_ONLY_PNG", "1");
    @cDefine("STBI_NO_SIMD", "1");
    @cInclude("stb_image.h");
    @cInclude("cairo/cairo.h");
    @cInclude("dbus/dbus.h");
});
