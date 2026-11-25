/* A perspective tunnel built from seven-sided crystal vaults and engraved brass. */
(() => {
  'use strict';

  const turn = 2 * Math.PI;
  const sides = 7;
  const panels = sides * 2;
  const step = turn / panels;
  const scaleStep = 1.53;
  const {cos, sin, min, max} = Math;
  const limit = value => min(1, max(0, Number(value) || 0));

  // Engraving is fixed to each vault. Cache the fine curves once, then scale the
  // same metalwork through perspective as each vault passes the camera.
  function engraving() {
    const rim = new Path2D(), lip = new Path2D(), scroll = new Path2D(), line = new Path2D();
    const studs = new Path2D(), gems = new Path2D(), arch = new Path2D(), lace = new Path2D();
    for (let i = 0; i < panels; i++) {
      const a = i * step;
      const r = i % 2 ? .945 : 1.04;
      const x = cos(a), y = sin(a);
      if (i === 0) {
        rim.moveTo(r * x, r * y);
        lip.moveTo(r * x * .971, r * y * .971);
      } else {
        rim.lineTo(r * x, r * y);
        lip.lineTo(r * x * .971, r * y * .971);
      }
      studs.moveTo(r * x + .005, r * y);
      studs.arc(r * x, r * y, .005, 0, turn);
    }
    rim.closePath();
    lip.closePath();
    for (let sector = 0; sector < sides; sector++) {
      const a = (2 * sector + 1) * step;
      const x = cos(a), y = sin(a);
      // Local coordinates run tangentially across each arch, then radially out.
      const pt = (u, v) => [v * x - u * y, v * y + u * x];
      const move = (p, u, v) => p.moveTo(...pt(u, v));
      const to = (p, u, v) => p.lineTo(...pt(u, v));
      const curve = (p, u, v, s, t, j, k) => p.bezierCurveTo(...pt(u, v), ...pt(s, t), ...pt(j, k));
      for (const sign of [-1, 1]) {
        move(arch, 0, .892);
        curve(arch, sign * .083, .837, sign * .16, .827, sign * .385, .9);
        curve(arch, sign * .265, .894, sign * .159, .911, sign * .096, .934);
        curve(arch, sign * .061, .948, sign * .022, .935, 0, .892);
        move(lace, 0, .892);
        curve(lace, sign * .055, .882, sign * .104, .846, sign * .20, .862);
        curve(lace, sign * .265, .872, sign * .276, .891, sign * .24, .895);
        curve(lace, sign * .192, .898, sign * .175, .872, sign * .20, .872);
        move(lace, sign * .116, .855);
        to(lace, sign * .134, .88);
        to(lace, sign * .109, .904);
        to(lace, sign * .088, .88);
        lace.closePath();
        move(scroll, 0, .91);
        curve(scroll, sign * .091, .936, sign * .092, .997, sign * .236, .948);
        curve(scroll, sign * .307, .923, sign * .324, .933, sign * .358, .927);
        move(scroll, sign * .039, .926);
        curve(scroll, sign * .115, .963, sign * .127, .997, sign * .167, .981);
        curve(scroll, sign * .195, .97, sign * .173, .951, sign * .158, .965);
        move(line, sign * .009, .91);
        curve(line, sign * .115, .929, sign * .17, .927, sign * .252, .913);
        curve(line, sign * .314, .903, sign * .335, .9, sign * .375, .902);
      }
      move(gems, 0, .889);
      to(gems, .023, .927);
      to(gems, 0, .955);
      to(gems, -.023, .927);
      gems.closePath();
    }
    return {rim, lip, scroll, line, studs, gems, arch, lace};
  }

  // Jewel walls use a broad value range: the recessed face, the polished ridge,
  // and the sliver that catches the light have different cuts of the same stone.
  const stone = [
    [107, 72, 180], [135, 85, 190], [78, 68, 165], [48, 125, 164], [25, 147, 132], [63, 171, 144],
    [42, 115, 133], [92, 79, 168]
  ].map(([r, g, b]) => Array.from({length: 96}, (_, i) => {
    const k = i / 60;
    return 'rgb(' + min(255, Math.round(6 + r * k)) + ',' + min(255, Math.round(5 + g * k)) + ',' +
        min(255, Math.round(14 + b * k)) + ')';
  }));
  const ink = (hue, value) => stone[hue][min(95, max(0, Math.round(value)))];

  function face(ctx, color, points) {
    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.moveTo(points[0], points[1]);
    for (let i = 2; i < points.length; i += 2) ctx.lineTo(points[i], points[i + 1]);
    ctx.closePath();
    ctx.fill();
  }

  function wall(ctx, back, front, lightPhase, mid, high) {
    const b = back.points, f = front.points;
    const distanceLight = min(1, front.radius / front.unit);
    const world = front.world * turn / 12;
    for (let i = 0; i < panels; i++) {
      const k = i * 2, j = ((i + 1) % panels) * 2;
      const bx = b[k], by = b[k + 1], cx = b[j], cy = b[j + 1];
      const fx = f[k], fy = f[k + 1], gx = f[j], gy = f[j + 1];
      const theta = (i + .5) * step + front.angle;
      const local = .5 + .5 * cos(2 * theta - .8 + .44 * sin(world + theta));
      const hue =
          (Math.round(3.4 + 2.9 * sin(theta * 1.9 + .42 * cos(world)) + .35 * cos(i + world)) + 8) % 8;
      const value = (16 + 11 * local + 4 * sin(world + theta)) * (.7 + .3 * distanceLight);
      // A raised, off-centre ridge divides each trapezoid into four crystal faces.
      const across = .35 + .12 * cos(world + 2 * theta);
      const along = .43 + .13 * sin(theta + world);
      const nx = (bx + (cx - bx) * across) * (1 - along) + (fx + (gx - fx) * across) * along;
      const ny = (by + (cy - by) * across) * (1 - along) + (fy + (gy - fy) * across) * along;
      const glint = (.5 + .5 * cos(3 * theta + lightPhase + .52 * sin(world))) ** 3;
      let lit = ink(hue, value + (13 + 9 * mid) * glint);
      let shade = ink(hue, value * (i % 2 ? 1.38 : 1.00));
      if (front.radius > front.unit * .1) {
        // Twin reflection bands break across the cut rather than illuminating
        // the entire wall equally. Each panel refracts its neighbour's colour.
        const tone = ctx.createLinearGradient(bx, by, gx, gy);
        const shift = .35 + .18 * cos(theta + world + lightPhase);
        tone.addColorStop(0, ink(hue, value * .48));
        tone.addColorStop(shift, ink(hue, value * .91));
        tone.addColorStop(shift + .17, ink(hue, value * (1.66 + .52 * glint)));
        tone.addColorStop(1, ink((hue + 1) % 8, value * .59));
        lit = tone;
        const mirror = ctx.createLinearGradient(cx, cy, fx, fy);
        mirror.addColorStop(0, ink(hue, value * .45));
        mirror.addColorStop(.62, ink((hue + 1) % 8, value * (1.16 + .7 * glint)));
        mirror.addColorStop(1, ink(hue, value * .54));
        shade = mirror;
      }
      face(ctx, ink(hue, value * .50), [bx, by, cx, cy, nx, ny]);
      face(ctx, lit, [cx, cy, gx, gy, nx, ny]);
      face(ctx, ink(hue, value * (i % 2 ? .55 : .78)), [gx, gy, fx, fy, nx, ny]);
      face(ctx, shade, [fx, fy, bx, by, nx, ny]);

      // Parallel cleavage planes leave long streaks in the mineral, following
      // the ridge instead of stretching a flat texture across the viewport.
      ctx.strokeStyle = ink(hue, value + 6 + 14 * glint);
      ctx.lineWidth = max(.38, front.radius * .00125);
      ctx.beginPath();
      ctx.moveTo(bx, by);
      ctx.lineTo(nx, ny);
      ctx.lineTo(gx, gy);
      if (front.radius > 70) {
        for (let n = 1; n <= 3; n++) {
          const t = n * .078, shift = n * .046;
          ctx.moveTo(bx + (cx - bx) * shift, by + (cy - by) * shift);
          ctx.lineTo(nx + (cx - nx) * t, ny + (cy - ny) * t);
          ctx.lineTo(gx + (cx - gx) * t, gy + (cy - gy) * t);
        }
      }
      ctx.stroke();
      if (front.radius > 31) {
        // A long transparent spear is cut out of the wall, with one bright
        // reflective bevel and one dark one. Its point projects into the nave.
        const px = bx * .81 + fx * .19, py = by * .81 + fy * .19;
        const qx = nx * .48 + gx * .52, qy = ny * .48 + gy * .52;
        const lx = nx + (cx - nx) * .16, ly = ny + (cy - ny) * .16;
        const tx = nx + (fx - nx) * .08, ty = ny + (fy - ny) * .08;
        face(ctx, ink(hue, value * (1.44 + .85 * glint)), [px, py, lx, ly, qx, qy]);
        face(ctx, ink((hue + 1) % 8, value * .72), [px, py, tx, ty, qx, qy]);
        ctx.strokeStyle = ink(hue, value * (2.00 + .53 * glint));
        ctx.lineWidth = max(.43, front.radius * .0016);
        ctx.beginPath();
        ctx.moveTo(px, py);
        ctx.lineTo(lx, ly);
        ctx.lineTo(qx, qy);
        ctx.stroke();
      }
      if (front.radius > 22) {
        // A longitudinal brass seam gives the eye a continuous line into depth.
        ctx.strokeStyle = i % 2 ? 'rgba(178,131,77,.46)' : 'rgba(205,170,103,.66)';
        ctx.lineWidth = max(.45, front.radius * (.00145 + .0006 * high));
        ctx.beginPath();
        ctx.moveTo(bx, by);
        ctx.lineTo(fx, fy);
        ctx.stroke();
      }
    }
  }

  function portal(ctx, gate, metal, high, phase) {
    const radius = gate.radius;
    if (radius < 4) return;
    const scale = min(1, radius / (gate.unit * .46));
    const brightness = .54 + .2 * scale + .12 * high + .065 * cos(gate.world * turn / 12 + phase);
    ctx.save();
    ctx.translate(gate.x, gate.y);
    ctx.rotate(gate.angle);
    ctx.scale(radius, radius);
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    ctx.strokeStyle = 'rgba(16,9,24,.87)';
    ctx.lineWidth = max(.025, 1 / radius);
    ctx.stroke(metal.rim);
    ctx.globalAlpha = brightness;
    ctx.strokeStyle = '#d39a54';
    ctx.lineWidth = max(.0055, .65 / radius);
    ctx.stroke(metal.rim);
    ctx.strokeStyle = '#efca7d';
    ctx.lineWidth = max(.0032, .45 / radius);
    ctx.stroke(metal.lip);
    if (radius > 17) {
      if (gate.world % 2 === 0) {
        ctx.fillStyle = 'rgba(36,20,26,.77)';
        ctx.fill(metal.arch);
        ctx.strokeStyle = '#e5b875';
        ctx.lineWidth = max(.0038, .53 / radius);
        ctx.stroke(metal.arch);
        ctx.strokeStyle = '#da9a57';
        ctx.lineWidth = max(.0021, .38 / radius);
        ctx.stroke(metal.lace);
      }
      ctx.strokeStyle = '#ffc17a';
      ctx.lineWidth = max(.00275, .49 / radius);
      ctx.stroke(metal.scroll);
      ctx.strokeStyle = '#ac7049';
      ctx.lineWidth = max(.0018, .39 / radius);
      ctx.stroke(metal.line);
      ctx.fillStyle = '#ffdc9b';
      ctx.fill(metal.studs);
      ctx.fillStyle = '#77d9c9';
      ctx.fill(metal.gems);
      ctx.lineWidth = max(.0016, .36 / radius);
      ctx.strokeStyle = '#ffe0a2';
      ctx.stroke(metal.gems);
    }
    ctx.restore();
  }

  function glow(ctx, x, y, r, rgb, strength) {
    const g = ctx.createRadialGradient(x, y, 0, x, y, r);
    g.addColorStop(0, 'rgba(' + rgb + ',' + strength + ')');
    g.addColorStop(.34, 'rgba(' + rgb + ',' + strength * .40 + ')');
    g.addColorStop(1, 'rgba(' + rgb + ',0)');
    ctx.fillStyle = g;
    ctx.fillRect(x - r, y - r, r * 2, r * 2);
  }

  window.createTunnelFallback = canvas => {
    const ctx = canvas.getContext('2d', {alpha: false});
    let metal = engraving();
    const gates = Array.from({length: 22}, () => ({points: new Float32Array(panels * 2)}));
    function draw(timeSeconds, bands) {
      if (!ctx || !metal || !canvas.width || !canvas.height) return;
      const w = canvas.width, h = canvas.height, unit = min(w * .57, h * .82);
      const time = Number.isFinite(timeSeconds) ? timeSeconds : 0;
      const loop = ((time % 48) + 48) % 48 / 48, phase = turn * loop;
      const bass = limit(bands && bands[0]), mid = limit(bands && bands[1]), high = limit(bands && bands[2]);
      // Twelve gates pass in one circuit. Each gate's facets and engraving have
      // a twelve-gate repeat, so the end joins the start with the same velocity.
      const travel = 12 * loop, counter = Math.floor(travel), fraction = travel - counter;
      const focusX = w * .5 + unit * .078 * sin(phase + .45),
            focusY = h * .48 + unit * .05 * sin(2 * phase - .28);
      let count = 0;
      const farthest = Math.hypot(w, h) * 1.25;
      for (let k = 0; k < gates.length; k++) {
        const g = gates[k], d = k + fraction;
        const r = unit * .0092 * Math.pow(scaleStep, d) * (1 + .027 * bass);
        const world = k - counter;
        const relief = r / (unit + r);
        const angle = .07 * d + .12 * sin(d * .36 + phase) + .20 * sin(phase) + .06 * mid * cos(phase + 1.2);
        const x = focusX + .20 * r * cos(phase + d * .29) - .09 * r * sin(2 * phase - d * .31);
        const y = focusY + .17 * r * sin(phase + d * .27 + .9);
        g.x = x;
        g.y = y;
        g.radius = r;
        g.unit = unit;
        g.angle = angle;
        g.world = world;
        for (let i = 0; i < panels; i++) {
          const a = angle + i * step, span = r * (i % 2 ? .945 : 1.04);
          g.points[2 * i] = x + span * cos(a);
          g.points[2 * i + 1] = y + span * sin(a);
        }
        count++;
        if (r > farthest * (1 + .2 * relief)) break;
      }
      ctx.save();
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.globalAlpha = 1;
      ctx.globalCompositeOperation = 'source-over';
      ctx.fillStyle = '#130f28';
      ctx.fillRect(0, 0, w, h);
      for (let k = 1; k < count; k++) {
        wall(ctx, gates[k - 1], gates[k], phase, mid, high);
        portal(ctx, gates[k - 1], metal, high, phase);
      }
      // A small luminous throat reads through the progressively tighter arches.
      ctx.globalCompositeOperation = 'screen';
      glow(ctx, focusX - unit * .52, focusY - unit * .32, unit * .91, '70,28,123', .18);
      glow(ctx, focusX + unit * .55, focusY + unit * .23, unit * .92, '18,111,102', .16);
      glow(ctx, focusX, focusY, unit * .23, '90,68,133', .39 + .08 * bass);
      glow(ctx, focusX, focusY, unit * .048, '253,178,84', .61 + .09 * mid);
      glow(ctx, focusX, focusY, unit * .012, '255,235,174', .92);
      ctx.globalCompositeOperation = 'source-over';
      const vignette =
          ctx.createRadialGradient(focusX, focusY, unit * .42, focusX, focusY, Math.hypot(w, h) * .61);
      vignette.addColorStop(0, 'rgba(4,2,15,0)');
      vignette.addColorStop(1, 'rgba(4,2,15,.53)');
      ctx.fillStyle = vignette;
      ctx.fillRect(0, 0, w, h);
      ctx.restore();
    }
    return {
      draw,
      dispose() {
        metal = null;
        gates.length = 0;
      }
    };
  };
})();
