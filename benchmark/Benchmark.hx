/**
 * HashLink Architecture Benchmark Suite
 *
 * A self-contained benchmark that exercises key performance areas:
 *   - Integer arithmetic (Fibonacci)
 *   - Floating-point math (N-Bodies simulation)
 *   - Memory allocation / GC pressure (Binary Trees)
 *   - Array traversal (Int + Float arrays)
 *   - String operations
 *   - Hash map operations
 *   - Mandelbrot (mixed float + allocation)
 *   - Virtual method dispatch (polymorphic calls)
 *   - Matrix/vector math (4x4 multiply, transforms)
 *   - Closure/lambda creation and invocation
 *   - Dynamic type field access
 *   - Object allocation churn (linked list create/discard)
 *
 * Outputs machine-readable JSON for easy comparison between architectures.
 */
class Benchmark {

    static var results:Array<{name:String, ms:Float, checksum:Dynamic}> = [];

    //──────────────────────────────────────────────────────────────
    // Harness
    //──────────────────────────────────────────────────────────────

    static function bench(name:String, iterations:Int, f:() -> Dynamic):Void {
        // Warmup
        for (_ in 0...3)
            f();

        var best = Math.POSITIVE_INFINITY;
        var total = 0.0;
        var checksum:Dynamic = null;

        for (_ in 0...iterations) {
            var t0 = haxe.Timer.stamp();
            checksum = f();
            var elapsed = (haxe.Timer.stamp() - t0) * 1000.0; // ms
            total += elapsed;
            if (elapsed < best)
                best = elapsed;
        }

        var avg = total / iterations;
        results.push({name: name, ms: avg, checksum: checksum});
        Sys.println('  $name: avg=${fmtMs(avg)}  best=${fmtMs(best)}  (checksum=$checksum)');
    }

    static function fmtMs(v:Float):String {
        return Std.string(Math.round(v * 100) / 100) + " ms";
    }

    //──────────────────────────────────────────────────────────────
    // Benchmarks
    //──────────────────────────────────────────────────────────────

    /** Recursive Fibonacci – pure integer call overhead */
    static function fib(n:Int):Int {
        if (n <= 1)
            return 1;
        return fib(n - 1) + fib(n - 2);
    }

    static function benchFib():Dynamic {
        return fib(36);
    }

    /** N-Bodies (planetary simulation) – floating point + struct-like access */
    static function benchNBodies():Dynamic {
        var bodies = NBody.create();
        NBody.offsetMomentum(bodies);
        for (_ in 0...250000)
            NBody.advance(bodies, 0.01);
        return Std.int(NBody.energy(bodies) * 1000000);
    }

    /** Binary trees – GC allocation pressure */
    static function benchBinaryTrees():Dynamic {
        var n = 12;
        var minDepth = 4;
        var maxDepth = Std.int(Math.max(minDepth + 2, n));
        var stretchDepth = maxDepth + 1;
        var check = Tree.make(0, stretchDepth).itemCheck();
        var result = check;
        var longLived = Tree.make(0, maxDepth);
        var depth = minDepth;
        while (depth <= maxDepth) {
            var iterations = 1 << (maxDepth - depth + minDepth);
            check = 0;
            for (i in 0...iterations) {
                check += Tree.make(i, depth).itemCheck();
                check += Tree.make(-i, depth).itemCheck();
            }
            result ^= check;
            depth += 2;
        }
        result ^= longLived.itemCheck();
        return result;
    }

    /** Float array – SIMD-friendly sequential float ops */
    static function benchFloatArray():Dynamic {
        var a:Array<Float> = [for (i in 0...10000) 1.0 / (i + 1)];
        for (_ in 0...400) {
            for (i in 0...a.length)
                a[i] += i;
            for (i in 1...a.length)
                a[i] /= i;
            for (i in 0...a.length)
                a[i] = Math.sqrt(a[i]);
        }
        var tot = 0.0;
        for (v in a)
            tot += v;
        return Std.int(tot * 100);
    }

    /** Int array – integer array traversal */
    static function benchIntArray():Dynamic {
        var a:Array<Int> = [for (i in 0...10000) i];
        for (_ in 0...1000) {
            for (i in 0...a.length)
                a[i] += i;
            for (i in 1...a.length)
                a[i] = Std.int(a[i] / i);
        }
        var tot = 0;
        for (v in a)
            tot += v;
        return tot;
    }

    /** String operations – concatenation, hashing, comparison */
    static function benchString():Dynamic {
        var hash = 0;
        for (iter in 0...100) {
            var buf = new StringBuf();
            for (i in 0...5000)
                buf.add(String.fromCharCode(65 + (i % 26)));
            var s = buf.toString();
            hash ^= s.length;
            // Substring search
            var idx = s.indexOf("XYZ");
            hash ^= (idx == -1) ? 0 : idx;
            // Split
            var parts = s.split("M");
            hash ^= parts.length;
        }
        return hash;
    }

    /** HashMap – insert + lookup + iteration */
    static function benchHashMap():Dynamic {
        var map = new Map<Int, Int>();
        var n = 100000;
        for (i in 0...n)
            map.set(i * 31 + 17, i);

        var sum = 0;
        for (i in 0...n) {
            var v = map.get(i * 31 + 17);
            if (v != null)
                sum += v;
        }
        // Iteration
        for (v in map)
            sum ^= v;
        return sum;
    }

    /** Mandelbrot – mixed float compute + allocation */
    static function benchMandelbrot():Dynamic {
        var width = 200;
        var height = 200;
        var maxIter = 500;
        var checksum = 0;
        for (py in 0...height) {
            for (px in 0...width) {
                var x0 = (px - width / 2) * 4.0 / width;
                var y0 = (py - height / 2) * 4.0 / height;
                var x = 0.0;
                var y = 0.0;
                var iter = 0;
                while (x * x + y * y <= 4.0 && iter < maxIter) {
                    var xt = x * x - y * y + x0;
                    y = 2.0 * x * y + y0;
                    x = xt;
                    iter++;
                }
                checksum += iter;
            }
        }
        return checksum;
    }

    /** Virtual dispatch – polymorphic method calls through interface/class hierarchy */
    static function benchVirtualDispatch():Dynamic {
        // Create a mixed array of different Shape subclasses
        var shapes:Array<Shape> = [];
        for (i in 0...2000) {
            switch (i % 4) {
                case 0: shapes.push(new Circle(i * 0.1));
                case 1: shapes.push(new Rectangle(i * 0.1, i * 0.2));
                case 2: shapes.push(new Triangle(i * 0.1, i * 0.2));
                case _: shapes.push(new Ellipse(i * 0.1, i * 0.05));
            }
        }
        var total = 0.0;
        // Polymorphic dispatch: each call resolves through vtable
        for (_ in 0...500) {
            for (s in shapes) {
                total += s.area();
                total += s.perimeter();
            }
        }
        return Std.int(total) & 0x7FFFFFFF;
    }

    /** Matrix math – 4x4 matrix multiply (core of 3D engines) */
    static function benchMatrixMath():Dynamic {
        var m = Mat4.identity();
        var r = Mat4.identity();
        var checksum = 0.0;
        for (iter in 0...50000) {
            // Build a rotation + translation matrix
            var angle = iter * 0.01;
            var cos = Math.cos(angle);
            var sin = Math.sin(angle);
            m.set(0, cos); m.set(1, -sin); m.set(2, 0); m.set(3, 0);
            m.set(4, sin); m.set(5, cos);  m.set(6, 0); m.set(7, 0);
            m.set(8, 0);   m.set(9, 0);    m.set(10, 1); m.set(11, 0);
            m.set(12, iter * 0.001); m.set(13, iter * 0.002); m.set(14, iter * 0.003); m.set(15, 1);
            // Multiply
            r = Mat4.multiply(r, m);
            // Transform a point
            var px = r.get(0) * 1.0 + r.get(4) * 2.0 + r.get(8) * 3.0 + r.get(12);
            var py = r.get(1) * 1.0 + r.get(5) * 2.0 + r.get(9) * 3.0 + r.get(13);
            var pz = r.get(2) * 1.0 + r.get(6) * 2.0 + r.get(10) * 3.0 + r.get(14);
            checksum += px + py + pz;
        }
        return Std.int(checksum) & 0x7FFFFFFF;
    }

    /** Closure/lambda – function object creation and invocation */
    static function benchClosures():Dynamic {
        var sum = 0.0;
        for (iter in 0...200) {
            // Create closures that capture different variables
            var funcs:Array<() -> Float> = [];
            for (i in 0...1000) {
                var captured = i * 0.5 + iter;
                funcs.push(function():Float {
                    return Math.sin(captured) + Math.cos(captured * 0.7);
                });
            }
            // Invoke them
            for (f in funcs) {
                sum += f();
            }
        }
        return Std.int(sum * 1000) & 0x7FFFFFFF;
    }

    /** Dynamic type – runtime type checks and Dynamic field access */
    static function benchDynamic():Dynamic {
        var objects:Array<Dynamic> = [];
        // Mix of different object types stored as Dynamic
        for (i in 0...2000) {
            switch (i % 4) {
                case 0: objects.push({x: i * 1.0, y: i * 2.0, z: i * 3.0, name: "point"});
                case 1: objects.push({x: i * 0.5, y: i * 1.5, w: i * 2.5, name: "vec4"});
                case 2: objects.push({r: i % 256, g: (i * 7) % 256, b: (i * 13) % 256, name: "color"});
                case _: objects.push({value: i, scale: i * 0.1, name: "scalar"});
            }
        }
        var total = 0.0;
        for (_ in 0...200) {
            for (obj in objects) {
                // Dynamic field access
                var n:String = obj.name;
                if (n == "point" || n == "vec4") {
                    total += (obj.x : Float) + (obj.y : Float);
                } else if (n == "color") {
                    total += (obj.r : Float) + (obj.g : Float);
                } else {
                    total += (obj.value : Float) * (obj.scale : Float);
                }
            }
        }
        return Std.int(total) & 0x7FFFFFFF;
    }

    /** Object allocation churn – create/discard many small objects rapidly */
    static function benchObjectChurn():Dynamic {
        var checksum = 0;
        for (_ in 0...300) {
            // Allocate a batch of small linked-list nodes
            var head:ListNode = null;
            for (i in 0...5000) {
                head = new ListNode(i, head);
            }
            // Walk and sum
            var node = head;
            while (node != null) {
                checksum += node.value;
                node = node.next;
            }
            // head goes out of scope → GC collects 5000 nodes
        }
        return checksum & 0x7FFFFFFF;
    }

    //──────────────────────────────────────────────────────────────
    // Main
    //──────────────────────────────────────────────────────────────

    public static function main() {
        var iters = 5;

        // Parse optional iteration count from args
        var args = Sys.args();
        if (args.length > 0) {
            var n = Std.parseInt(args[0]);
            if (n != null && n > 0)
                iters = n;
        }

        Sys.println('HashLink Architecture Benchmark');
        Sys.println('  iterations per test: $iters');
        Sys.println('─────────────────────────────────────');

        bench("fibonacci",     iters, benchFib);
        bench("nbodies",       iters, benchNBodies);
        bench("binary-trees",  iters, benchBinaryTrees);
        bench("float-array",   iters, benchFloatArray);
        bench("int-array",     iters, benchIntArray);
        bench("string-ops",    iters, benchString);
        bench("hashmap",       iters, benchHashMap);
        bench("mandelbrot",    iters, benchMandelbrot);
        bench("vtable-dispatch", iters, benchVirtualDispatch);
        bench("matrix-math",    iters, benchMatrixMath);
        bench("closures",       iters, benchClosures);
        bench("dynamic-type",   iters, benchDynamic);
        bench("object-churn",   iters, benchObjectChurn);

        Sys.println('─────────────────────────────────────');

        // JSON output for scripted comparison
        var json = new StringBuf();
        json.add("[");
        for (i in 0...results.length) {
            if (i > 0) json.add(",");
            var r = results[i];
            json.add('{"name":"${r.name}","ms":${r.ms},"checksum":"${r.checksum}"}');
        }
        json.add("]");
        Sys.println('JSON: ${json.toString()}');
    }
}

//──────────────────────────────────────────────────────────────────
// Helper classes (self-contained in one compilation unit)
//──────────────────────────────────────────────────────────────────

/** N-Body simulation (from Benchmarks Game) */
class NBody {
    public var x:Float;
    public var y:Float;
    public var z:Float;
    public var vx:Float;
    public var vy:Float;
    public var vz:Float;
    public var mass:Float;

    public function new(x:Float, y:Float, z:Float, vx:Float, vy:Float, vz:Float, mass:Float) {
        this.x = x;    this.y = y;    this.z = z;
        this.vx = vx;  this.vy = vy;  this.vz = vz;
        this.mass = mass;
    }

    static inline var PI = 3.141592653589793;
    static inline var SOLAR_MASS = 4.0 * PI * PI;
    static inline var DAYS_PER_YEAR = 365.24;

    public static function create():Array<NBody> {
        return [
            new NBody(0, 0, 0, 0, 0, 0, SOLAR_MASS), // Sun
            new NBody( // Jupiter
                4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01,
                1.66007664274403694e-03 * DAYS_PER_YEAR, 7.69901118419740425e-03 * DAYS_PER_YEAR, -6.90460016972063023e-05 * DAYS_PER_YEAR,
                9.54791938424326609e-04 * SOLAR_MASS),
            new NBody( // Saturn
                8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01,
                -2.76742510726862411e-03 * DAYS_PER_YEAR, 4.99852801234917238e-03 * DAYS_PER_YEAR, 2.30417297573763929e-05 * DAYS_PER_YEAR,
                2.85885980666130812e-04 * SOLAR_MASS),
            new NBody( // Uranus
                1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01,
                2.96460137564761618e-03 * DAYS_PER_YEAR, 2.37847173959480950e-03 * DAYS_PER_YEAR, -2.96589568540237556e-05 * DAYS_PER_YEAR,
                4.36624404335156298e-05 * SOLAR_MASS),
            new NBody( // Neptune
                1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01,
                2.68067772490389322e-03 * DAYS_PER_YEAR, 1.62824170038242295e-03 * DAYS_PER_YEAR, -9.51592254519715870e-05 * DAYS_PER_YEAR,
                5.15138902046611451e-05 * SOLAR_MASS),
        ];
    }

    public static function offsetMomentum(bodies:Array<NBody>):Void {
        var px = 0.0, py = 0.0, pz = 0.0;
        for (b in bodies) {
            px += b.vx * b.mass;
            py += b.vy * b.mass;
            pz += b.vz * b.mass;
        }
        bodies[0].vx = -px / SOLAR_MASS;
        bodies[0].vy = -py / SOLAR_MASS;
        bodies[0].vz = -pz / SOLAR_MASS;
    }

    public static function advance(bodies:Array<NBody>, dt:Float):Void {
        var size = bodies.length;
        for (i in 0...size) {
            var a = bodies[i];
            for (j in (i + 1)...size) {
                var b = bodies[j];
                var dx = a.x - b.x;
                var dy = a.y - b.y;
                var dz = a.z - b.z;
                var dist = Math.sqrt(dx * dx + dy * dy + dz * dz);
                var mag = dt / (dist * dist * dist);
                a.vx -= dx * b.mass * mag;
                a.vy -= dy * b.mass * mag;
                a.vz -= dz * b.mass * mag;
                b.vx += dx * a.mass * mag;
                b.vy += dy * a.mass * mag;
                b.vz += dz * a.mass * mag;
            }
        }
        for (b in bodies) {
            b.x += dt * b.vx;
            b.y += dt * b.vy;
            b.z += dt * b.vz;
        }
    }

    public static function energy(bodies:Array<NBody>):Float {
        var e = 0.0;
        var size = bodies.length;
        for (i in 0...size) {
            var a = bodies[i];
            e += 0.5 * a.mass * (a.vx * a.vx + a.vy * a.vy + a.vz * a.vz);
            for (j in (i + 1)...size) {
                var b = bodies[j];
                var dx = a.x - b.x;
                var dy = a.y - b.y;
                var dz = a.z - b.z;
                e -= (a.mass * b.mass) / Math.sqrt(dx * dx + dy * dy + dz * dz);
            }
        }
        return e;
    }
}

/** Binary tree for GC stress test */
class Tree {
    public var left:Tree;
    public var right:Tree;
    public var item:Int;

    public function new(l:Tree, r:Tree, i:Int) {
        left = l;
        right = r;
        item = i;
    }

    public function itemCheck():Int {
        if (left == null)
            return item;
        return item + left.itemCheck() - right.itemCheck();
    }

    public static function make(item:Int, depth:Int):Tree {
        if (depth > 0)
            return new Tree(make(2 * item - 1, depth - 1), make(2 * item, depth - 1), item);
        return new Tree(null, null, item);
    }
}

/** Shape hierarchy for virtual dispatch benchmark */
class Shape {
    public function new() {}
    public function area():Float { return 0; }
    public function perimeter():Float { return 0; }
}

class Circle extends Shape {
    var radius:Float;
    public function new(r:Float) { super(); this.radius = r; }
    override public function area():Float { return 3.14159265 * radius * radius; }
    override public function perimeter():Float { return 2.0 * 3.14159265 * radius; }
}

class Rectangle extends Shape {
    var w:Float;
    var h:Float;
    public function new(w:Float, h:Float) { super(); this.w = w; this.h = h; }
    override public function area():Float { return w * h; }
    override public function perimeter():Float { return 2.0 * (w + h); }
}

class Triangle extends Shape {
    var base:Float;
    var height:Float;
    public function new(b:Float, h:Float) { super(); this.base = b; this.height = h; }
    override public function area():Float { return 0.5 * base * height; }
    override public function perimeter():Float {
        var side = Math.sqrt(base * base / 4.0 + height * height);
        return base + 2.0 * side;
    }
}

class Ellipse extends Shape {
    var a:Float;
    var b:Float;
    public function new(a:Float, b:Float) { super(); this.a = a; this.b = b; }
    override public function area():Float { return 3.14159265 * a * b; }
    override public function perimeter():Float {
        // Ramanujan approximation
        var h = (a - b) * (a - b) / ((a + b) * (a + b));
        return 3.14159265 * (a + b) * (1.0 + 3.0 * h / (10.0 + Math.sqrt(4.0 - 3.0 * h)));
    }
}

/** Simple 4x4 matrix stored as flat Float array */
class Mat4 {
    var d:Array<Float>;

    public function new() {
        d = [for (_ in 0...16) 0.0];
    }

    public inline function get(i:Int):Float { return d[i]; }
    public inline function set(i:Int, v:Float):Void { d[i] = v; }

    public static function identity():Mat4 {
        var m = new Mat4();
        m.set(0, 1); m.set(5, 1); m.set(10, 1); m.set(15, 1);
        return m;
    }

    public static function multiply(a:Mat4, b:Mat4):Mat4 {
        var r = new Mat4();
        for (row in 0...4) {
            for (col in 0...4) {
                var sum = 0.0;
                for (k in 0...4) {
                    sum += a.get(row * 4 + k) * b.get(k * 4 + col);
                }
                r.set(row * 4 + col, sum);
            }
        }
        return r;
    }
}

/** Linked list node for object churn benchmark */
class ListNode {
    public var value:Int;
    public var next:ListNode;

    public function new(v:Int, n:ListNode) {
        value = v;
        next = n;
    }
}
