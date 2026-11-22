export function sphere(size = 200) {
  const canvas = document.createElement('canvas');
  canvas.className = 'particle-sphere'; canvas.setAttribute('aria-hidden', 'true');
  const ratio = Math.min(window.devicePixelRatio || 1, 2);
  canvas.width = canvas.height = size * ratio;
  canvas.style.width = canvas.style.height = size + 'px';
  const ctx = canvas.getContext('2d'); ctx.scale(ratio, ratio);
  const points = Array.from({ length: 90 }, (_, i) => {
    const y = 1 - 2 * (i + .5) / 90, r = Math.sqrt(1 - y * y), a = i * Math.PI * (3 - Math.sqrt(5));
    return [Math.cos(a) * r, y, Math.sin(a) * r];
  });
  const edges = [];
  for (let i = 0; i < points.length; i++) for (let j = i + 1; j < points.length; j++) {
    if (Math.hypot(...points[i].map((v, k) => v - points[j][k])) < .47) edges.push([i, j]);
  }
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  let start;
  function draw(time) {
    if (!canvas.isConnected) return;
    start ??= time;
    const a = reduced.matches ? .4 : (time - start) * .00013, c = Math.cos(a), s = Math.sin(a);
    const state = canvas.closest('[data-state]')?.dataset.state || document.documentElement.dataset.voice;
    const pulse = !reduced.matches && ['speaking', 'listening'].includes(state) ? 1 + .025 * Math.sin(time * .008) : 1;
    const radius = size * .39 * pulse;
    const projected = points.map(([x, y, z]) => {
      const rx = x * c + z * s, rz = z * c - x * s;
      return [size / 2 + rx * radius, size / 2 + (y * .96 - rz * .28) * radius, rz * .96 + y * .28];
    });
    ctx.clearRect(0, 0, size, size);
    const glow = ctx.createRadialGradient(size/2,size/2,0,size/2,size/2,size/2);
    glow.addColorStop(0,'#dca3260c');glow.addColorStop(1,'#dca32600');ctx.fillStyle=glow;ctx.fillRect(0,0,size,size);
    ctx.lineWidth = .65;
    for (const [i,j] of edges) {
      const p=projected[i],q=projected[j];ctx.strokeStyle=`rgba(237,177,46,${.08 + (p[2]+q[2]+2)*.055})`;
      ctx.beginPath();ctx.moveTo(p[0],p[1]);ctx.lineTo(q[0],q[1]);ctx.stroke();
    }
    for (const [x,y,z] of [...projected].sort((a,b)=>a[2]-b[2])) {
      ctx.fillStyle=`rgba(245,187,55,${.25+(z+1)*.33})`;ctx.beginPath();ctx.arc(x,y,1+(z+1)*.65,0,Math.PI*2);ctx.fill();
    }
    if (!reduced.matches) requestAnimationFrame(draw);
  }
  requestAnimationFrame(draw);
  return canvas;
}
