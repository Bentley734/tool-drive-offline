/* Original parametric filament studies for the Tool Drive player. */
(() => {
  'use strict';
  const TAU = Math.PI * 2;
  const {sin, cos, pow, abs, max, min, sqrt} = Math;
  const palettes = {
    ember: ['#070307', '#421321', '#9e2640', '#fc663a', '#ffd19a'],
    tidal: ['#01060e', '#0b2846', '#145598', '#18d9bc', '#c0fff2'],
    prism: ['#080711', '#342448', '#8f65f7', '#68c7c2', '#f8c785']
  };
  const stops = {
    ember: [[0, '#50172f'], [.21, '#e74944'], [.5, '#ffd593'], [.7, '#fc8241'], [1, '#9c2043']],
    tidal: [
      [0, '#3543a0'], [.2, '#7385ff'], [.43, '#87e2ee'], [.62, '#0ee6c3'], [.84, '#379bba'], [1, '#514097']
    ],
    prism: [
      [0, '#f65768'], [.16, '#ffb15a'], [.33, '#a6d886'], [.46, '#23cacc'], [.62, '#4e69f1'],
      [.8, '#aa58f4'], [1, '#efb87e']
    ]
  };

  function tabulate(count, sample) {
    const rows = [];
    for (let index = 0; index <= count; index++) rows.push(sample(index / count));
    return rows;
  }

  // A section stores its spine, half-width vector and curved transverse bow.
  // Each thread follows the same continuous surface at a different latitude.
  function thread(ctx, rows, s, reverse, move) {
    const bow = (1 - s * s);
    const direction = reverse ? -1 : 1;
    let index = reverse ? rows.length - 1 : 0;
    for (let i = 0; i < rows.length; i++, index += direction) {
      const [x, y, wx, wy, bx, by] = rows[index];
      const px = x + s * wx + bow * bx, py = y + s * wy + bow * by;
      if (!i && move)
        ctx.moveTo(px, py);
      else
        ctx.lineTo(px, py);
    }
  }

  // Reusing the same grains gives the caustics texture without temporal noise.
  const grains = [];
  let grainSeed = 78191;
  function grainNoise() {
    grainSeed = (Math.imul(1664525, grainSeed) + 1013904223) >>> 0;
    return grainSeed / 4294967296;
  }
  for (let i = 0; i < 1350; i++) {
    const u = grainNoise(), sign = grainNoise() < .5 ? -1 : 1;
    grains.push([
      u, sign * (.85 + .45 * grainNoise() + pow(grainNoise(), 8) * 1.36),
      .0012 + .0028 * pow(grainNoise(), 4)
    ]);
  }
  function caustics(ctx, rows, ink, count, light) {
    ctx.fillStyle = ink;
    ctx.globalAlpha = light;
    ctx.beginPath();
    for (let i = 0; i < count; i++) {
      const [u, s, grain] = grains[i], index = u * (rows.length - 1), j = Math.floor(index), f = index - j;
      const a = rows[j], b = rows[j + 1], bow = 1 - min(1, s * s);
      const x = a[0] + f * (b[0] - a[0]) + s * a[2] + bow * a[4];
      const y = a[1] + f * (b[1] - a[1]) + s * a[3] + bow * a[5];
      ctx.rect(x, y, grain, grain);
    }
    ctx.fill();
    ctx.globalAlpha = 1;
  }

  function ribbon(ctx, rows, count, gradient, light, thickness, ribs) {
    ctx.fillStyle = ctx.strokeStyle = gradient;
    ctx.beginPath();
    thread(ctx, rows, -1, false, true);
    thread(ctx, rows, 1, true, false);
    ctx.closePath();
    ctx.globalAlpha = .105 * light;
    ctx.fill();
    for (let i = 0; i < count; i++) {
      const f = i / (count - 1), s = 2 * f - 1;
      const edge = i === 0 || i === count - 1;
      const glint = pow(.5 + .5 * cos(f * 29 + .7), 8);
      ctx.lineWidth = thickness * (edge ? 1.75 : .72 + .65 * glint);
      ctx.globalAlpha = min(.95, light * (edge ? .9 : .12 + .23 * abs(s) + .35 * glint));
      ctx.beginPath();
      thread(ctx, rows, s, false, true);
      ctx.stroke();
    }
    // Curved cross-sections pick up light in the spiral's glass chambers.
    if (ribs) {
      ctx.lineWidth = thickness * .68;
      for (let i = 2; i < rows.length - 1; i += ribs) {
        const [x, y, wx, wy, bx, by] = rows[i];
        ctx.globalAlpha = light * (.065 + .1 * pow(.5 + .5 * sin(i * .31), 3));
        ctx.beginPath();
        ctx.moveTo(x - wx, y - wy);
        ctx.quadraticCurveTo(x + 2 * bx, y + 2 * by, x + wx, y + wy);
        ctx.stroke();
      }
    }
    ctx.globalAlpha = 1;
  }

  function gradient(ctx, x0, y0, x1, y1, colors) {
    const g = ctx.createLinearGradient(x0, y0, x1, y1);
    for (const [offset, color] of colors) g.addColorStop(offset, color);
    return g;
  }
  function halo(ctx, x, y, r, color, strength) {
    const g = ctx.createRadialGradient(x, y, 0, x, y, r);
    g.addColorStop(0, color + 'ae');
    g.addColorStop(.28, color + '53');
    g.addColorStop(.62, color + '18');
    g.addColorStop(1, color + '00');
    ctx.fillStyle = g;
    ctx.globalAlpha = strength;
    ctx.fillRect(x - r, y - r, 2 * r, 2 * r);
    ctx.globalAlpha = 1;
  }

  // Accumulate a deterministic nonlinear IFS into a transparent material. Two
  // opposing branch maps repeatedly grow smaller copies inside the main curl.
  // Keeping log density preserves both the bright spine and its fine fronds.
  function flameMaterial(id) {
    const width = 520, height = 184;
    const density = new Uint32Array(width * height), hue = new Float32Array(width * height);
    let x = 0, y = 0, color = .5, seed = 468921;
    for (let i = 0; i < 230000; i++) {
      seed = (Math.imul(1664525, seed) + 1013904223) >>> 0;
      const p = seed / 4294967296;
      let nx, ny, tint;
      if (p < .785) {
        nx = .831 * x + .071 * y;
        ny = -.053 * x + .843 * y + 1.48;
        tint = .66;
      } else if (p < .89) {
        nx = .24 * x - .29 * y;
        ny = .27 * x + .24 * y + 1.18;
        tint = .21;
      } else if (p < .99) {
        nx = -.19 * x + .315 * y;
        ny = .24 * x + .22 * y + .55;
        tint = .91;
      } else {
        nx = .041 * x;
        ny = .17 * y;
        tint = .35;
      }
      // A positional twist inside the iteration bends the descendants too.
      const angle = .061 * sin(ny * .84) + .039 * sin(nx * 1.65);
      x = nx * cos(angle) - ny * sin(angle);
      y = nx * sin(angle) + ny * cos(angle);
      color = .61 * color + .39 * tint;
      if (i < 32) continue;
      const axial = y / 10.05;
      const transverse = x * .278 - .115 * axial;
      const curl = sin(Math.PI * axial);
      const u = .018 + .955 * axial + .12 * curl * sin(transverse * 4.1 + axial * 6.1);
      const v = .103 + .79 * (.50 + .46 * transverse + .14 * curl * sin(8.0 * axial + 3.2 * transverse));
      const px = Math.floor(u * width), py = Math.floor(v * height);
      if (px < 0 || px >= width || py < 0 || py >= height) continue;
      const index = py * width + px;
      density[index]++;
      hue[index] += color;
    }
    const colors = {
      ember: [[197, 56, 87], [255, 166, 81], [255, 225, 163]],
      tidal: [[73, 80, 220], [43, 222, 203], [172, 246, 255]],
      prism: [[151, 71, 248], [70, 225, 223], [250, 177, 110]]
    }[id];
    const points = [];
    // Axial order keeps consecutive samples on the same curved section.
    for (let px = 0; px < width; px++)
      for (let py = 0; py < height; py++) {
        const i = py * width + px;
        if (!density[i]) continue;
        const heat = min(1, Math.log1p(density[i]) * .21);
        const shade =
            max(0, min(1, 1.12 * (hue[i] / density[i] - .26) + .24 * heat + .21 * sin(5.6 * px / width)));
        const from = shade < .5 ? colors[0] : colors[1], to = shade < .5 ? colors[1] : colors[2];
        const blend = shade < .5 ? shade * 2 : shade * 2 - 1;
        const energy = .068 + heat * .88;
        points.push((px + .5) / width, (py + .5) / height * 2 - 1);
        for (let channel = 0; channel < 3; channel++)
          points.push((from[channel] + (to[channel] - from[channel]) * blend) * energy);
      }
    return {points: new Float32Array(points), cells: width * height};
  }

  // Splat the log-density field through the actual local frame of the ribbon.
  // Neighboring samples share a continuous surface even across a sharp fold.
  function layFlame(ctx, field, rows, start, end, spread, hand, light) {
    const m = ctx.getTransform(), scale = field.scale;
    const xa = m.a * scale, xb = m.c * scale, ya = m.b * scale, yb = m.d * scale;
    const fieldWidth = field.image.width, fieldHeight = field.image.height;
    const pixels = field.image.data, material = field.material, points = material.points;
    const span = (end - start) * (rows.length - 1), head = start * (rows.length - 1);
    const sw = hand * spread;
    let last = -1, x = 0, y = 0, dx = 0, dy = 0, wx = 0, wy = 0, dwx = 0, dwy = 0, gain = 0;
    for (let i = 0; i < points.length; i += 5) {
      const u = head + points[i] * span, j = Math.floor(u), f = u - j, v = points[i + 1];
      if (j !== last) {
        last = j;
        const a = rows[j], b = rows[min(j + 1, rows.length - 1)];
        const cx = a[0] + .49 * a[4], cy = a[1] + .49 * a[5];
        const tx = b[0] + .49 * b[4] - cx, ty = b[1] + .49 * b[5] - cy;
        x = xa * cx + xb * cy + m.e * scale;
        y = ya * cx + yb * cy + m.f * scale;
        dx = xa * tx + xb * ty;
        dy = ya * tx + yb * ty;
        wx = sw * (xa * a[2] + xb * a[3]);
        wy = sw * (ya * a[2] + yb * a[3]);
        dwx = sw * (xa * (b[2] - a[2]) + xb * (b[3] - a[3]));
        dwy = sw * (ya * (b[2] - a[2]) + yb * (b[3] - a[3]));
        const footprint = 2 * span * abs(dx * wy - dy * wx) / material.cells;
        gain = light * min(1.6, .008 + 1.35 * footprint);
      }
      const xx = x + f * dx + v * (wx + f * dwx), yy = y + f * dy + v * (wy + f * dwy);
      if (xx < 0 || yy < 0 || xx >= fieldWidth - 1 || yy >= fieldHeight - 1) continue;
      const px = xx | 0, py = yy | 0, rx = xx - px, ry = yy - py, cell = 4 * (py * fieldWidth + px);
      const r = points[i + 2] * gain, g = points[i + 3] * gain, b = points[i + 4] * gain;
      for (let row = 0; row < 2; row++) {
        const dest = cell + row * 4 * fieldWidth, weight = row ? ry : 1 - ry;
        const left = weight * (1 - rx), right = weight * rx;
        pixels[dest] += r * left;
        pixels[dest + 1] += g * left;
        pixels[dest + 2] += b * left;
        pixels[dest + 3] = 255;
        pixels[dest + 4] += r * right;
        pixels[dest + 5] += g * right;
        pixels[dest + 6] += b * right;
        pixels[dest + 7] = 255;
      }
    }
  }

  // Pinched spirals recur at several scales, like tributaries in a flame.
  function coil(ctx, x, y, heading, width, height, hand, ink, light, t) {
    ctx.save();
    ctx.translate(x, y);
    ctx.rotate(heading - hand * 1.82);
    const startAngle = hand * .14 * sin(t * .26);
    const rows = tabulate(58, u => {
      const r = pow(1 - u, 1.45), a = hand * (u * 10.6 + .14 * sin(t * .26 + u * 4));
      const c = cos(a), sn = sin(a), w = (.15 * r + .012 * (1 - u)) * min(1, u * 14);
      return [
        width * (r * c - cos(startAngle)), height * (r * sn - sin(startAngle)), width * w * (c - .61 * sn),
        height * w * (sn + .61 * c), width * w * .69 * sn * sin(a * .8), -height * w * .69 * c * sin(a * .8)
      ];
    });
    ribbon(ctx, rows, 9, ink, light, .00145, 0);
    ctx.restore();
  }

  function ember(ctx, t, low, mid, high, material) {
    const drift = .075 * sin(t * .16);
    ctx.save();
    ctx.rotate(-.18 + drift);
    ctx.scale(.96, .84);
    ctx.translate(-.035, 0);
    halo(ctx, 0, 0, 1.12, '#c73e27', .43 + .17 * low);
    for (let tier = 0; tier < 3; tier++) {
      const size = [1, .58, .29][tier];
      const arms = tier === 1 ? 6 : 7;
      const layerTurn = [.06, .48, -.25][tier] + .08 * sin(t * .19 + tier * 2) + .09 * mid;
      for (let k = 0; k < arms; k++) {
        const az = k * TAU / arms + layerTurn;
        const pulse = .5 + .5 * sin(k * 2.4 + t * .32);
        const span = size * (.94 + .07 * pulse + .06 * low);
        const rows = tabulate(tier ? 48 : 70, u => {
          const arc = sin(Math.PI * u), lobe = pow(max(0, arc), 1.12);
          const r = span * (.105 + .88 * lobe);
          const a = az + 1.05 * u - .32 * sin(TAU * u) + .12 * mid * sin(TAU * u + .5) +
              .09 * sin(t * .2 + u * 5 + k) * arc;
          const c = cos(a), sn = sin(a), twist = TAU * u + .32 * sin(t * .2 + k) + .5;
          const w = span * (.016 + .162 * pow(arc, .75));
          const radial = w * (.63 * cos(twist) + .33), tangential = w * (.92 * sin(twist) + .48);
          return [
            r * c, r * sn, radial * c - tangential * sn, radial * sn + tangential * c,
            w * (.42 * c + .56 * sn) * sin(twist - .6), w * (.42 * sn - .56 * c) * sin(twist - .6)
          ];
        });
        const ink = gradient(ctx, 0, 0, cos(az + .49) * span, sin(az + .49) * span, stops.ember);
        ribbon(
            ctx, rows, tier ? 18 : 31, ink, (tier ? .75 : .82) + .15 * pulse + .15 * high,
            tier ? .00165 : .0020, 0);
        if (tier < 2) {
          if (!tier) layFlame(ctx, material, rows, .18, .84, 2.40, -1, .56 + .10 * high);
          caustics(ctx, rows, ink, tier ? 190 : 550, .38 + .21 * high);
          const branch = Math.floor(rows.length * .62), origin = rows[branch], next = rows[branch + 1];
          const heading = Math.atan2(next[1] - origin[1], next[0] - origin[0]);
          coil(
              ctx, origin[0] + origin[2], origin[1] + origin[3], heading, span * (.18 + .04 * pulse),
              span * .14, -1, ink, .72 + .20 * high, t + k);
          if (!tier) {
            const inner = rows[16];
            coil(
                ctx, inner[0] - inner[2], inner[1] - inner[3], az + .42, span * .12, span * .08, 1, ink,
                .53, t + k);
          }
        }
      }
    }
    halo(ctx, 0, 0, .135, '#f9af61', .5 + .27 * low);
    ctx.restore();
  }

  function tidal(ctx, t, low, mid, high, material) {
    ctx.save();
    ctx.rotate(-.14 + .045 * sin(t * .15));
    ctx.translate(-.11, -.07);
    halo(ctx, -.10, .05, 1.19, '#1a7092', .43 + .17 * low);
    const turn = .17 * sin(t * .14) + .09 * mid;
    for (let shell = 2; shell >= 0; shell--) {
      const rows = tabulate(shell ? 110 : 176, u => {
        const phase = u * 12.65 - 5.82 + turn + shell * .1;
        const radius = (.013 + 1.1 * pow(u, 1.93)) * (1 + .065 * low) * (1 + shell * .13);
        const c = cos(phase), sn = sin(phase);
        const undulate = sin(phase * 1.6 + t * .39);
        const x = radius * (1.23 * c + .16 * sin(phase * 2 + .37)) - .025;
        const y = radius * (.73 * sn + .085 * undulate);
        const taper = min(1, max(0, (1 - u) * 9));
        const w = (.004 + .253 * pow(u, 1.24)) * taper * (shell ? .40 : 1.0);
        const twist = phase * .85 + .37 * sin(t * .23 + phase) + mid * .48;
        const radial = w * (.75 + .62 * cos(twist)), tangential = w * .78 * sin(twist);
        const wx = radial * c - tangential * sn, wy = .85 * (radial * sn + tangential * c);
        return [
          x, y, wx, wy, w * (.84 * c + .62 * sn) * sin(twist + .85),
          w * (.63 * sn - .73 * c) * sin(twist + .85)
        ];
      });
      const ink = gradient(ctx, -.89, -.55, 1.0, .25, stops.tidal);
      ribbon(
          ctx, rows, shell ? 15 : 53, ink, shell ? .26 + .07 * high : .98 + .22 * high,
          shell ? .0018 : .0026, shell ? 0 : 2);
      if (!shell) {
        layFlame(ctx, material, rows, .18, .62, 2.50, 1, .73 + .10 * mid);
        layFlame(ctx, material, rows, .51, .91, 2.40, -1, .76 + .10 * high);
        layFlame(ctx, material, rows, .72, 1, 2.16, 1, .58);
        caustics(ctx, rows, ink, 1350, .55 + .24 * high);
        for (let j = 0; j < 8; j++) {
          const i = Math.round((.38 + j * .079) * (rows.length - 1)), row = rows[i], next = rows[i + 1];
          const a = Math.atan2(next[1] - row[1], next[0] - row[0]), span = .05 + .023 * j;
          coil(
              ctx, row[0] - .68 * row[2], row[1] - .68 * row[3], a - .44, span, span * .76, -1, ink,
              .51 + .12 * high, t + j);
        }
      }
    }
    ctx.restore();
  }

  function prism(ctx, t, low, mid, high, material) {
    ctx.save();
    ctx.rotate(-.26 + .06 * sin(t * .12));
    ctx.scale(.89, .85);
    halo(ctx, -.53, .16, .89, '#be724f', .26 + .08 * low);
    halo(ctx, .58, -.13, 1.03, '#6554ac', .40 + .13 * low);
    const phase = .16 * sin(t * .21);
    const ink = gradient(ctx, -1.4, -.12, 1.34, .33, stops.prism);
    // Back-to-front lengths give the central crossing its folded depth.
    for (let facet = 0; facet < 4; facet++) {
      const rows = tabulate(64, u => {
        const a = (facet + u) * Math.PI / 2, c = cos(a), sn = sin(a);
        const x = 1.18 * sn + .13 * sin(3 * a + .28) + .04 * mid * sin(2 * a + phase);
        const y = .48 * sin(2 * a + phase) + .16 * c + .074 * cos(3 * a - t * .19);
        const dx = 1.18 * c + .39 * cos(3 * a + .28) + .08 * mid * cos(2 * a + phase);
        const dy = .96 * cos(2 * a + phase) - .16 * sn - .222 * sin(3 * a - t * .19);
        const speed = max(.15, sqrt(dx * dx + dy * dy)), nx = -dy / speed, ny = dx / speed;
        const twist = 1.5 * a + .52 * sin(2 * a) + .33 * sin(t * .28) + .3 * mid;
        const w = (.135 + .118 * pow(.5 + .5 * cos(2 * a - .6), .85)) * (1 + .15 * low);
        const flat = cos(twist), depth = sin(twist);
        return [
          x, y, w * (nx * flat + .33 * depth), w * (ny * flat - .84 * depth),
          w * (nx * .65 + .19) * cos(twist + .6), w * (ny * .65 - .52) * cos(twist + .6)
        ];
      });
      const reflection = rows.map(([x, y, wx, wy, bx, by], i) => {
        const bend = sin(Math.PI * i / (rows.length - 1));
        return [
          x - .76 * wx - .10 * bend, y - .76 * wy + .17 * bend, .65 * wx + .05 * bend,
          .65 * wy - .06 * bend, bx * .81, by * .81
        ];
      });
      ribbon(ctx, reflection, 19, ink, .40 + .10 * high, .0014, 0);
      ribbon(ctx, rows, 49, ink, (facet === 0 || facet === 3 ? .94 : .70) + .22 * high, .0022, 4);
      layFlame(ctx, material, rows, 0, 1, 2.20, facet % 2 ? 1 : -1, .70 + .12 * high);
      layFlame(ctx, material, reflection, .33, .92, 1.95, facet % 2 ? -1 : 1, .42);
      caustics(ctx, rows, ink, 750, .48 + .21 * high);
    }
    ctx.restore();
  }

  function atmosphere(surface, id) {
    const ctx = surface.getContext('2d'), w = surface.width, h = surface.height;
    const pal = palettes[id], unit = min(w / 2.85, h / 1.99);
    ctx.fillStyle = pal[0];
    ctx.fillRect(0, 0, w, h);
    ctx.translate(w * .5, h * .5);
    ctx.scale(unit, unit);
    halo(ctx, -.32, .08, 1.92, pal[1], .7);
    halo(ctx, 1.48, -.73, 1.45, pal[2], .16);
    // Seeded dust gives the space a fixed fine grain as the sculpture moves.
    let seed = 246763;
    function rand() {
      seed = (Math.imul(1664525, seed) + 1013904223) >>> 0;
      return seed / 4294967296;
    }
    const halfW = w / (2 * unit), halfH = h / (2 * unit);
    for (let n = 0; n < 480; n++) {
      const x = (2 * rand() - 1) * halfW, y = (2 * rand() - 1) * halfH;
      const size = .00135 + pow(rand(), 5) * .0034;
      ctx.fillStyle = n % 5 === 0 ? pal[4] : pal[3];
      ctx.globalAlpha = .055 + .17 * rand();
      ctx.beginPath();
      ctx.arc(x, y, size, 0, TAU);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
  }

  window.createFlameVisualizer = canvas => {
    const ctx = canvas.getContext('2d', {alpha: false});
    const background = document.createElement('canvas'), bloom = document.createElement('canvas');
    const glow = bloom.getContext('2d');
    const art = {ember, tidal, prism};
    const materials = new Map();
    const fieldCanvas = document.createElement('canvas'), fieldCtx = fieldCanvas.getContext('2d');
    const field = {scale: 1, image: null, material: null};
    let preset = 'ember', backdropPreset = '', disposed = false;
    function level(bands, begin, end) {
      if (!bands || !bands.length) return 0;
      const start = min(bands.length - 1, Math.floor(bands.length * begin)),
            stop = max(start + 1, Math.ceil(bands.length * end));
      let sum = 0;
      for (let i = start; i < stop; i++) sum += min(1, max(0, Number(bands[i]) || 0));
      return sum / (stop - start);
    }
    function draw(timeSeconds, bands) {
      if (disposed || !ctx || !canvas.width || !canvas.height) return;
      const w = canvas.width, h = canvas.height, t = Number.isFinite(timeSeconds) ? timeSeconds : 0;
      if (background.width !== w || background.height !== h || backdropPreset !== preset) {
        background.width = w;
        background.height = h;
        atmosphere(background, preset);
        bloom.width = max(2, Math.round(w / 16));
        bloom.height = max(2, Math.round(h / 16));
        if (!field.image || field.sourceWidth !== w || field.sourceHeight !== h) {
          field.scale = min(1, 720 / max(w, h));
          fieldCanvas.width = max(1, Math.ceil(w * field.scale));
          fieldCanvas.height = max(1, Math.ceil(h * field.scale));
          field.image = fieldCtx.createImageData(fieldCanvas.width, fieldCanvas.height);
          field.sourceWidth = w;
          field.sourceHeight = h;
        }
        backdropPreset = preset;
      }
      if (!materials.has(preset)) materials.set(preset, flameMaterial(preset));
      field.material = materials.get(preset);
      field.image.data.fill(0);
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.globalCompositeOperation = 'source-over';
      ctx.globalAlpha = 1;
      ctx.drawImage(background, 0, 0);
      const scale = min(w / 2.85, h / 1.99);
      ctx.setTransform(scale, 0, 0, scale, w * .5, h * .5);
      ctx.globalCompositeOperation = 'lighter';
      ctx.lineJoin = 'round';
      ctx.lineCap = 'round';
      // The native tap supplies three normalized bass, mid and treble envelopes.
      if (bands && bands.length === 3) {
        const band = i => max(0, min(1, Number(bands[i]) || 0));
        art[preset](ctx, t, band(0), band(1), band(2), field);
      } else {
        art[preset](ctx, t, level(bands, 0, .17), level(bands, .17, .60), level(bands, .60, 1), field);
      }
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      fieldCtx.putImageData(field.image, 0, 0);
      ctx.drawImage(fieldCanvas, 0, 0, w, h);
      glow.drawImage(canvas, 0, 0, bloom.width, bloom.height);
      ctx.globalCompositeOperation = 'screen';
      ctx.globalAlpha = .61;
      ctx.drawImage(bloom, 0, 0, w, h);
      ctx.globalAlpha = 1;
      ctx.globalCompositeOperation = 'source-over';
    }
    return {
      draw,
      setPreset(id) {
        if (Object.prototype.hasOwnProperty.call(art, id)) preset = id;
      },
      dispose() {
        disposed = true;
        background.width = background.height = bloom.width = bloom.height = 1;
        fieldCanvas.width = fieldCanvas.height = 1;
        field.image = field.material = null;
        materials.clear();
      }
    };
  };
})();
