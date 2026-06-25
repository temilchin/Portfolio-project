/* ============================================================
   anon-scene.js — shared forest experience for every Anonymous page.
   Injects: gooey filter + ink cursor, self-looping forest video bg,
   tint/grain, and a Three.js layer of exactly 3 objects themed per page.
   Opt in with <body data-scene="submit|wall|reveal|admin">.
   Requires three.js loaded before this file. Degrades gracefully.
   ============================================================ */
(function () {
  // ---- 1. Inject shared background + cursor DOM (once) ----
  if (!document.getElementById("bg")) {
    var dom =
      '<svg id="goo-filter" width="0" height="0" aria-hidden="true" style="position:absolute">' +
        '<defs><filter id="goo">' +
          '<feGaussianBlur in="SourceGraphic" stdDeviation="6" result="blur"/>' +
          '<feColorMatrix in="blur" mode="matrix" values="1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 34 -14" result="goo"/>' +
          '<feComposite in="SourceGraphic" in2="goo" operator="atop"/>' +
        '</filter></defs>' +
      '</svg>' +
      '<video id="bg" autoplay muted loop playsinline preload="auto">' +
        '<source src="./forest-loop.mp4" type="video/mp4"></video>' +
      '<div class="bg-tint"></div><div class="grain"></div>' +
      '<div id="scene" aria-hidden="true"></div>' +
      '<div id="ink-cursor"></div>';
    document.body.insertAdjacentHTML("afterbegin", dom);
  }

  // ---- 2. Forest ink cursor (gooey moss-green trail; fine pointer only) ----
  (function () {
    var fine = window.matchMedia && window.matchMedia("(pointer: fine)").matches;
    if (!fine) return;
    var host = document.getElementById("ink-cursor");
    if (!host) return;
    document.body.classList.add("has-cursor");
    var AMOUNT = 18, SINE_DOTS = Math.floor(AMOUNT * 0.3), DOT = 24, IDLE_MS = 150, CHASE = 0.35;
    var mouse = { x: -300, y: -300 }, dots = [], idle = false, idleID = null;
    function Dot(i) {
      this.index = i; this.x = -300; this.y = -300;
      this.scale = 1 - 0.05 * i;
      this.range = DOT / 2 - (DOT / 2) * this.scale + 2;
      this.anglespeed = 0.05; this.angleX = 0; this.angleY = 0; this.lockX = 0; this.lockY = 0;
      var el = document.createElement("span");
      var op = Math.max(0.72 - i * 0.026, 0.1);
      el.style.background = "rgba(150,196,128," + op.toFixed(2) + ")";
      this.el = el; host.appendChild(el);
    }
    Dot.prototype.lock = function () {
      this.lockX = this.x; this.lockY = this.y;
      this.angleX = Math.PI * 2 * Math.random(); this.angleY = Math.PI * 2 * Math.random();
    };
    Dot.prototype.draw = function () {
      if (idle && this.index > SINE_DOTS) {
        this.angleX += this.anglespeed; this.angleY += this.anglespeed;
        this.x = this.lockX + Math.sin(this.angleX) * this.range;
        this.y = this.lockY + Math.sin(this.angleY) * this.range;
      }
      this.el.style.transform = "translate(calc(" + this.x + "px - 50%), calc(" + this.y + "px - 50%)) scale(" + this.scale.toFixed(3) + ")";
    };
    for (var di = 0; di < AMOUNT; di++) dots.push(new Dot(di));
    function resetIdle() {
      clearTimeout(idleID); idle = false;
      idleID = setTimeout(function () { idle = true; for (var k = 0; k < dots.length; k++) dots[k].lock(); }, IDLE_MS);
    }
    (function loop() {
      var x = mouse.x, y = mouse.y;
      for (var i = 0; i < dots.length; i++) {
        var dot = dots[i], next = dots[i + 1] || dots[0];
        dot.x = x; dot.y = y;
        if (!idle || i <= SINE_DOTS) { x += (next.x - dot.x) * CHASE; y += (next.y - dot.y) * CHASE; }
        dot.draw();
      }
      requestAnimationFrame(loop);
    })();
    window.addEventListener("pointermove", function (e) { mouse.x = e.clientX; mouse.y = e.clientY; resetIdle(); }, { passive: true });
  })();

  // ---- 3. Three.js: exactly 3 objects, themed to the page's purpose ----
  (function () {
    var host = document.getElementById("scene");
    if (!window.THREE || !host) return;
    var theme = (document.body.getAttribute("data-scene") || "submit").toLowerCase();
    var reduce = window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches;
    var coarse = window.matchMedia && matchMedia("(pointer: coarse)").matches;
    var ACCENT = 0x8fb882, W = innerWidth, H = innerHeight;

    var renderer = new THREE.WebGLRenderer({ alpha: true, antialias: !coarse });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, coarse ? 1.5 : 2));
    renderer.setSize(W, H); host.appendChild(renderer.domElement);

    var scene = new THREE.Scene();
    var camera = new THREE.PerspectiveCamera(55, W / H, 0.1, 100); camera.position.z = 9;
    scene.add(new THREE.AmbientLight(0x8fb882, 0.5));
    var key = new THREE.DirectionalLight(0xeafff0, 0.8); key.position.set(2, 3, 5); scene.add(key);

    var objs = [], update = null, mx = 0, my = 0, tmx = 0, tmy = 0;
    function stdMat(opacity, emi) {
      return new THREE.MeshStandardMaterial({ color: 0xcfe6c4, emissive: ACCENT,
        emissiveIntensity: emi, metalness: 0.4, roughness: 0.3, transparent: true, opacity: opacity });
    }
    function edges(geo, op) {
      return new THREE.LineSegments(new THREE.EdgesGeometry(geo),
        new THREE.LineBasicMaterial({ color: ACCENT, transparent: true, opacity: op }));
    }

    if (theme === "wall") {
      // Wall: 3 glowing lanterns/orbs drifting upward — messages & wishes set free.
      var rimW = new THREE.PointLight(0x96c480, 1.3, 42); rimW.position.set(-4, -2, 6); scene.add(rimW);
      var spotsW = [{ x: -4.4, y: -2.4, z: -1, s: 0.7 }, { x: 4.6, y: -3.4, z: 0, s: 0.92 }, { x: 2.6, y: -1.6, z: -2.2, s: 0.55 }];
      for (var i = 0; i < 3; i++) {
        var gW = new THREE.SphereGeometry(spotsW[i].s, 32, 32);
        var mW = new THREE.Mesh(gW, stdMat(0.55, 0.95));
        mW.position.set(spotsW[i].x, spotsW[i].y, spotsW[i].z);
        mW.add(new THREE.PointLight(0x9fd089, 0.9, 9));
        mW.userData = { base: spotsW[i], sp: 0.4 + i * 0.12, ph: i * 2.0, rise: 1.5 + i * 0.5 };
        scene.add(mW); objs.push(mW);
      }
      update = function (t) {
        for (var i = 0; i < objs.length; i++) {
          var o = objs[i], u = o.userData;
          if (!reduce) {
            o.position.y = u.base.y + ((t * u.rise / 3) % 8);
            o.position.x = u.base.x + Math.sin(t * u.sp + u.ph) * 0.5 + mx * 1.4;
            o.rotation.y = t * 0.2;
          }
        }
      };
    } else if (theme === "reveal") {
      // Reveal: 3 nested rings spinning on different axes — a cipher / lock decoding an identity.
      var rimR = new THREE.PointLight(0x96c480, 1.3, 44); rimR.position.set(0, 0, 7); scene.add(rimR);
      var radii = [2.5, 1.75, 1.05];
      for (var i = 0; i < 3; i++) {
        var gR = new THREE.TorusGeometry(radii[i], 0.055, 16, 180);
        var mR = new THREE.Mesh(gR, stdMat(0.88, 0.6));
        mR.position.set(0.3, 0.1, -i * 0.4);
        mR.userData = { rx: (i === 0 ? 0.20 : 0.05), ry: (i === 1 ? 0.24 : 0.06), rz: (i === 2 ? 0.22 : 0.04) };
        scene.add(mR); objs.push(mR);
      }
      update = function (t) {
        for (var i = 0; i < objs.length; i++) {
          var o = objs[i], u = o.userData;
          if (!reduce) { o.rotation.x = t * u.rx; o.rotation.y = t * u.ry; o.rotation.z = t * u.rz; }
          o.position.x = 0.3 + mx * 0.9; o.position.y = 0.1 - my * 0.7;
        }
      };
    } else if (theme === "admin") {
      // Admin: 3 calm wireframe cubes — structured, dim, deliberately non-distracting.
      var spotsA = [{ x: -5.0, y: 2.2, z: -1, s: 1.1 }, { x: 5.2, y: -2.4, z: 0, s: 1.5 }, { x: 3.6, y: 2.9, z: -3, s: 0.9 }];
      for (var i = 0; i < 3; i++) {
        var gA = new THREE.BoxGeometry(spotsA[i].s, spotsA[i].s, spotsA[i].s);
        var wfA = edges(gA, 0.3);
        wfA.position.set(spotsA[i].x, spotsA[i].y, spotsA[i].z);
        wfA.userData = { base: spotsA[i], sp: 0.16 + i * 0.05, ph: i * 2.4 };
        scene.add(wfA); objs.push(wfA);
      }
      update = function (t) {
        for (var i = 0; i < objs.length; i++) {
          var o = objs[i], u = o.userData;
          if (!reduce) { o.rotation.x = t * u.sp; o.rotation.y = t * u.sp * 0.8; o.position.y = u.base.y + Math.sin(t * 0.3 + u.ph) * 0.25; }
          o.position.x = u.base.x + mx * 0.7;
        }
      };
    } else {
      // Submit (default): 3 crystalline shapes — a whispered secret taking form.
      var rimS = new THREE.PointLight(0x96c480, 1.4, 42); rimS.position.set(-5, -2, 6); scene.add(rimS);
      var geos = [new THREE.IcosahedronGeometry(1.15, 0), new THREE.OctahedronGeometry(0.95, 0), new THREE.TorusKnotGeometry(0.6, 0.2, 140, 18)];
      var spotsS = [{ x: -7.8, y: -4.0, z: -2, s: 1 }, { x: 7.9, y: -4.0, z: -1.5, s: 0.92 }, { x: 7.6, y: 4.0, z: -3, s: 0.74 }];
      for (var i = 0; i < 3; i++) {
        var mS = new THREE.Mesh(geos[i], stdMat(0.9, 0.5));
        mS.position.set(spotsS[i].x, spotsS[i].y, spotsS[i].z); mS.scale.setScalar(spotsS[i].s);
        mS.add(edges(geos[i], 0.45));
        mS.userData = { base: spotsS[i], rs: 0.10 + i * 0.05, ph: i * 2.1, dir: (i % 2 ? 1 : -1) };
        scene.add(mS); objs.push(mS);
      }
      update = function (t) {
        for (var i = 0; i < objs.length; i++) {
          var o = objs[i], u = o.userData;
          if (!reduce) {
            o.rotation.x = t * u.rs * 0.7 + i; o.rotation.y = t * u.rs;
            o.position.y = u.base.y + Math.sin(t * 0.6 + u.ph) * 0.38;
            o.position.x = u.base.x + mx * 1.7 * u.dir;
          }
        }
      };
    }

    if (!coarse) addEventListener("mousemove", function (e) {
      tmx = (e.clientX / innerWidth - 0.5); tmy = (e.clientY / innerHeight - 0.5);
    }, { passive: true });
    addEventListener("resize", function () {
      W = innerWidth; H = innerHeight; camera.aspect = W / H; camera.updateProjectionMatrix(); renderer.setSize(W, H);
    });

    var t0 = performance.now();
    (function frame(now) {
      var t = (now - t0) / 1000;
      mx += (tmx - mx) * 0.05; my += (tmy - my) * 0.05;
      if (update) update(t);
      camera.position.x = mx * 1.2; camera.position.y = -my * 1.0; camera.lookAt(0, 0, 0);
      renderer.render(scene, camera);
      requestAnimationFrame(frame);
    })(performance.now());
  })();
})();
