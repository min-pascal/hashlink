package metal;

/**
 * Metal driver interface for HashLink.
 */
@:hlNative("metal")
class Driver {
    /**
     * Initialize the Metal driver.
     * @return A handle to the Metal driver
     */
    public static function init() : MetalDriver {
        return null;
    }

    /**
     * Set a rendering target for Metal.
     * @param nativeWindow Native window handle (can be null for our test)
     * @param width Width of the rendering surface
     * @param height Height of the rendering surface
     */
    public static function set_target(nativeWindow : Dynamic, width : Int, height : Int) : Void {
    }

    /**
     * Clear the screen with the specified color.
     * @param r Red component (0-1)
     * @param g Green component (0-1)
     * @param b Blue component (0-1)
     * @param a Alpha component (0-1)
     */
    public static function clear(r : Float, g : Float, b : Float, a : Float) : Void {
    }

    /**
     * Free Metal resources.
     */
    public static function free() : Void {
    }
}

/**
 * Abstract type for Metal driver handle.
 */
@:hlNative("metal")
abstract MetalDriver(hl.Abstract<"metal_driver">) {
}
