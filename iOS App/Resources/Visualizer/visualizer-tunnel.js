/* Original toroidal raymarched architecture for the Tool Drive visualizer. */
(() => {
  'use strict';
  const vertex = `
    attribute vec2 aPosition;
    void main() { gl_Position = vec4(aPosition, 0.0, 1.0); }
  `;
  const fragment = `
    precision highp float;
    uniform vec2 uSize;
    uniform float uPhase;
    uniform vec3 uBands;
    const float PI = 3.14159265359;
    const float TAU = 6.28318530718;
    const float radius = 21.0;
    const float bays = 12.0;
    const float ringSpacing = TAU * radius / (8.0 * bays);

    mat2 rotate(float a) { float s=sin(a), c=cos(a); return mat2(c,s,-s,c); }
    vec3 lantern() { return vec3(-2.71+.13*sin(uPhase),.12*cos(2.0*uPhase),10.37); }

    vec3 reflectedLight(vec3 r) {
      vec3 key=normalize(vec3(-.42,.82,-.38));
      vec3 rim=normalize(vec3(.63,-.24,.74));
      float sky=pow(max(0.0,r.y),3.0);
      float strip=exp(-19.0*abs(dot(r,vec3(.49,.81,.32))-.24));
      float silver=pow(max(0.0,dot(key,r)),57.0);
      float violet=pow(max(0.0,dot(rim,r)),13.0);
      return vec3(.018,.021,.04) + vec3(.67,.56,.35)*sky + vec3(1.20,1.10,.76)*strip
        + vec3(3.5,2.7,1.54)*silver + vec3(.64,.21,1.58)*violet;
    }

    // A segment is one eighth of a closed torus. Its end matches the next
    // segment exactly, so the camera can keep advancing through the structure.
    vec4 torus(vec3 p) {
      vec2 toCenter = vec2(radius + p.x, p.z);
      float longitude = 8.0*atan(toCenter.y, toCenter.x) + uPhase;
      vec2 section = vec2(length(toCenter)-radius,p.y);
      float twist = .175*sin(longitude+.22*sin(uPhase)) + .066*sin(3.0*longitude-uPhase);
      return vec4(length(section), atan(section.y, section.x)-twist, longitude, twist);
    }

    // Actual 3D intersections: a crystalline wall, faceted freestanding golden
    // arches, and eight thin helical rails. All distances are in world units.
    vec3 architecture(vec3 p) {
      vec4 q=torus(p);
      float facet=mod(q.y+PI/8.0,TAU/8.0)-PI/8.0;
      float apothem=q.x*cos(facet);
      float bay=q.z*bays/TAU, dz=(fract(bay+.5)-.5)*ringSpacing;
      float throat=1.42+.072*sin(q.z*2.0)+.022*uBands.x;
      float lateral=q.x*sin(facet), midBay=(fract(bay)-.5)*ringSpacing;
      float facetSlope=clamp(1.0-abs(lateral)*1.4-abs(midBay)*1.6,0.0,1.0);
      float wall=1.81-apothem-.09*facetSlope;
      float weave=24.0*q.y+2.0*q.z+uPhase;
      vec2 braid=.023*vec2(cos(weave),sin(weave));
      vec2 ringCoords=vec2(apothem-throat,dz);
      float arch=length(ringCoords+braid)-.022;
      float rim=min(length(ringCoords-braid)-.012,
        length(vec2(apothem-throat-.087,abs(dz)-.063))-.011);
      float rail=length(vec2(q.x-1.64,lateral))-.013;
      // Marquise-cut crystals protrude into alternating bays. An evolving
      // facet fold and a pronounced pointed crown give them actual parallax.
      vec2 window=rotate(.26*sin(q.z+uPhase)+.23*uBands.y)*vec2(lateral,midBay);
      vec2 cut=abs(window);
      float depth=abs(apothem-1.70);
      float crown=max(depth*1.08+.63*cut.x+.49*cut.y,depth*.68+.92*cut.x+.34*cut.y);
      crown=max(crown,depth*.63+.28*cut.x+.79*cut.y);
      float setting=.262+.039*cos(2.0*q.z+2.0*(q.y-facet));
      float gem=(crown-setting)*.74;
      float d=min(gem,min(wall,min(arch,min(rim,rail))));
      float material=d==gem ? 4.0 : (d==wall ? 0.0 : (d==rail ? 3.0 : (d==arch ? 1.0 : 2.0)));
      if(p.z>8.8 && p.z<12.0) {
        vec3 f=p-lantern();
        f.xy=rotate(.48+uPhase)*f.xy; f.xz=rotate(uPhase)*f.xz;
        vec3 a=abs(f);
        float core=(a.x+a.y+a.z-.58)*.577;
        float cage=min(length(vec2((a.x+a.z-.71)*.707,f.y)),
          length(vec2((a.z+a.y-.71)*.707,f.x)))-.020;
        if(min(core,cage)<d) { d=min(core,cage); material=core<cage?5.0:6.0; }
      }
      return vec3(d,material,dz);
    }

    float ink(float d,float width,float aa) { return 1.0-smoothstep(width,width+aa,abs(d)); }

    vec3 glasswork(vec4 q,float range,vec3 normal,vec3 view) {
      float theta=q.y, phase=q.z;
      float angle=theta*8.0/TAU+.5;
      float axial=phase*bays/TAU+.5;
      vec2 tile=fract(vec2(angle,axial))-.5;
      vec2 f=abs(tile);
      float bay=floor(axial), pane=floor(angle);
      float aa=clamp((.55+range*.76)/uSize.y,.001,.036);
      float temper=.5+.5*cos(bay*TAU/12.0*3.0+pane*TAU/8.0*3.0);
      float mixTone=smoothstep(.20,.85,temper+.15*sin(phase*2.0+theta*2.0));
      vec3 purple=vec3(.125,.027,.235), green=vec3(.012,.194,.157);
      vec3 glass=.54*mix(purple,green,mixTone);
      float diamond=f.x*.96+f.y;
      float cut=sin(5.0*PI*diamond+1.0)*cos(2.0*PI*(f.x-f.y));
      float iridescence=.50+.43*sin(phase*3.0-theta*3.0+cut);
      vec3 enamel=glass*(.35+.60*iridescence+.42*max(0.0,cut));
      enamel+=vec3(.027,.038,.082)*(.5+.5*normal.y);
      // Filigree follows the pane edges, then folds into successively smaller
      // cut-glass lozenges at the center of each vault.
      float border=min(.5-f.x,.5-f.y);
      float frame=ink(border-.033,.005,aa) + .36*ink(border-.064,.002,aa);
      float stepY=floor(f.y*14.0+.5)/14.0;
      float fret=ink(f.x + stepY - .59,.007,aa)*smoothstep(.14,.21,diamond);
      fret+=.48*ink(f.y + floor(f.x*14.0+.5)/14.0 - .55,.004,aa);
      vec2 fold=tile;
      float fractures=0.0;
      for(int i=0;i<3;i++) {
        float unfold=.19*sin(uPhase+float(i)*1.7+phase)+.16*uBands.y;
        fold=abs(rotate(PI*.25+unfold)*fold)-vec2(.17+.043*sin(uPhase+phase),.09+.019*uBands.y);
        fractures+=ink(abs(fold.x)+abs(fold.y)-.129,.0026,aa)*(.48/(1.0+float(i)));
      }
      // The central eightfold seal is an interlock of two square frames.
      vec2 oct=abs(rotate(PI*.25)*tile);
      float sealDistance=min(abs(max(f.x,f.y)-.126),abs(max(oct.x,oct.y)-.126));
      float seal=ink(sealDistance,.0045,aa)+.65*ink(length(tile)-.073,.003,aa);
      float facetLight=max(0.0,dot(normal,normalize(vec3(-.42,.75,-.51))));
      vec3 bronze=mix(vec3(.25,.094,.024),vec3(.88,.54,.16),.19+.81*facetLight);
      float detail=1.0-.84*smoothstep(3.0,12.0,range);
      enamel+=bronze*(frame*.23+fret*.32+seal*.46)*detail;
      enamel+=mix(vec3(.36,.18,.74),vec3(.13,.54,.48),mixTone)*fractures*detail;
      float vein=sin(3.0*theta+2.0*phase+.89*sin(phase*4.0-theta*6.0)+.20*uBands.y);
      float flow=.5+.5*cos(4.0*phase-2.0*uPhase+theta*3.0);
      vec3 plasma=mix(vec3(.34,.068,.78),vec3(.01,.82,.63),mixTone);
      enamel+=plasma*(.29+.32*flow+.38*uBands.z)*(exp(-abs(vein)*27.0)+.19*exp(-abs(vein)*5.0));
      float grazing=pow(clamp(1.0-abs(dot(normal,view)),0.0,1.0),3.0);
      return enamel+glass*(.08+.24*grazing);
    }

    vec3 reliefNormal(vec3 p,float travel) {
      float e=.0015+.00013*travel, base=architecture(p).x;
      return normalize(vec3(architecture(p+vec3(e,0,0)).x-base,
        architecture(p+vec3(0,e,0)).x-base,architecture(p+vec3(0,0,e)).x-base));
    }

    vec3 shade(vec3 p,vec3 rd,float d,vec3 hit) {
      vec4 q=torus(p);
      vec2 meridian=normalize(vec2(radius+p.x,p.z));
      vec3 radial=vec3(meridian.x,0.0,meridian.y), tangent=vec3(-meridian.y,0.0,meridian.x);
      float facet=mod(q.y+PI/8.0,TAU/8.0)-PI/8.0;
      float face=q.y-facet+q.w;
      vec3 faceOut=cos(face)*radial + vec3(0.0,sin(face),0.0);
      if(hit.y<.5) return glasswork(q,d,-faceOut,-rd);
      if(hit.y>3.5) {
        vec3 n=reliefNormal(p,d), mirror=reflect(rd,n), inside=refract(rd,n,.64);
        float fresnel=pow(1.0-clamp(dot(n,-rd),0.0,1.0),3.0);
        if(hit.y>5.5) return vec3(.63,.39,.11)*(reflectedLight(mirror)*2.7+.28)+vec3(.13,.07,.03);
        float az=q.y, longitude=q.z;
        vec2 uv=hit.y>4.5 ? (p-lantern()).xy*1.4 : vec2(q.y*8.0/TAU,longitude*bays/TAU);
        vec2 fold=abs(fract(uv)-.5);
        float seam=1.0, shift=uPhase+.6*sin(longitude)+.55*uBands.y;
        for(int k=0;k<3;k++) {
          fold=abs(rotate(.79+.34*sin(shift+float(k)*1.25))*fold)-vec2(.19,.105);
          seam=min(seam,abs(abs(fold.x)*.82+abs(fold.y)-.103));
        }
        float lightLine=exp(-seam*135.0);
        float spectrum=.5+.5*sin(2.0*az+2.0*longitude+.74*inside.x+shift);
        vec3 stone=mix(vec3(.085,.023,.189),vec3(.005,.205,.146),spectrum);
        vec3 flash=mix(vec3(.65,.31,1.05),vec3(.22,.94,.80),spectrum);
        float caustic=pow(max(0.0,.5+.5*sin(dot(inside,vec3(11.0,8.0,-7.0))+2.0*shift)),11.0);
        // Sample the etching behind the crown along its refracted ray. Opposing
        // planes split the inscription differently, like a cut piece of opal.
        vec3 submerged=glasswork(torus(p+inside*.35),d,-faceOut,-rd);
        vec3 transmitted=mix(submerged,submerged.brg,.20+.12*sin(2.0*shift+inside.y*4.0));
        vec3 result=stone*(.19+1.25*max(.0,-n.y)) + transmitted*(.76-.50*fresnel)
          + flash*(lightLine*.37+caustic*.22)+reflectedLight(mirror)*(.29+.92*fresnel)+flash*.22*fresnel;
        if(hit.y>4.5) result=result*1.33+mix(vec3(.06,.87,.49),vec3(.66,.12,1.12),caustic)*(.68+.36*uBands.x);
        return result;
      }
      vec3 n;
      vec3 pigment;
      if(hit.y>2.5) {
        float physical=q.y+q.w;
        vec3 localRad=radial*cos(physical)+vec3(0.0,sin(physical),0.0);
        vec3 localTan=-radial*sin(physical)+vec3(0.0,cos(physical),0.0);
        n=normalize(localRad*(q.x-1.64)+localTan*q.x*sin(facet));
        pigment=mix(vec3(.136,.045,.215),vec3(.032,.295,.28),.5+.5*sin(4.0*face+q.z*2.0));
      } else {
        n=reliefNormal(p,d);
        pigment=hit.y<1.5 ? vec3(.58,.238,.048) : vec3(.34,.16,.07);
      }
      vec3 lamp=normalize(vec3(-.44,.77,-.45));
      float facing=max(0.0,dot(n,-rd));
      float diffuse=.5+.5*dot(n,lamp);
      float glint=pow(max(0.0,dot(reflect(rd,n),lamp)),17.0);
      float trim=.5+.5*cos(32.0*q.y+.6*sin(q.z*2.0));
      if(hit.y<2.5) return vec3(.82,.53,.19)*reflectedLight(reflect(rd,n))*(1.59+.40*trim)
        +pigment*(.085+.35*diffuse)+vec3(.84,.52,.15)*pow(1.0-facing,2.0)*.62;
      return pigment*(.21+.55*diffuse)+reflectedLight(reflect(rd,n))*.38
        +vec3(.08,.26,.31)*pow(1.0-facing,2.0);
    }

    void main() {
      vec2 uv=(2.0*gl_FragCoord.xy-uSize)/uSize.y;
      vec2 aim=rotate(.047*sin(uPhase))*uv;
      vec3 ro=vec3(.054*sin(uPhase),.052*cos(2.0*uPhase),0.0);
      vec3 rd=normalize(vec3(aim.x-.118+.039*cos(uPhase),aim.y+.035*sin(uPhase),1.48));
      float travel=.02, haze=0.0;
      vec3 hit=vec3(0.0);
      bool found=false;
      for(int i=0;i<80;i++) {
        vec3 p=ro+rd*travel;
        hit=architecture(p);
        float epsilon=.00085+.00047*travel;
        if(hit.x<epsilon) { found=true; break; }
        if(travel>20.0) break;
        // Sparse low intensity scattering near architectural edges gives the
        // recesses a little reflected light without a screen-wide brightness pulse.
        haze+=.0020*exp(-9.0*max(0.0,hit.x))*(1.0-smoothstep(1.0,2.2,hit.y));
        travel+=clamp(hit.x*.89,.0015,1.20);
      }
      vec3 color=vec3(.014,.020,.046);
      if(found) color=shade(ro+rd*travel,rd,travel,hit);
      float mist=exp(-.085*travel);
      vec3 fog=mix(vec3(.019,.017,.060),vec3(.029,.083,.085),.5+.5*sin(uPhase));
      color=mix(fog,color,mist)+vec3(.24,.14,.38)*min(haze,.15);
      vec3 beacon=lantern()-ro;
      float ahead=dot(beacon,rd), distanceToBeam=length(beacon-rd*ahead);
      color+=vec3(.064,.52,.37)*exp(-distanceToBeam*4.1)*smoothstep(ahead-1.8,ahead-.3,travel);
      color=1.0-exp(-color*1.39);
      color=pow(max(color,vec3(0.0)),vec3(.80));
      gl_FragColor=vec4(color*(1.0-.13*smoothstep(.25,2.2,length(uv))),1.0);
    }
  `;

  window.createHyperspaceTunnel = canvas => {
    let gl;
    try {
      gl = canvas.getContext('webgl', {
        alpha: false, antialias: false, depth: false, stencil: false, preserveDrawingBuffer: false
      });
    } catch {
      return null;
    }
    if (!gl || gl.isContextLost()) return null;
    function compile(type, source) {
      const shader = gl.createShader(type);
      if (!shader) return null;
      gl.shaderSource(shader, source);
      gl.compileShader(shader);
      if (gl.getShaderParameter(shader, gl.COMPILE_STATUS)) return shader;
      gl.deleteShader(shader);
      return null;
    }
    const vs = compile(gl.VERTEX_SHADER, vertex);
    const fs = compile(gl.FRAGMENT_SHADER, fragment);
    const program = vs && fs ? gl.createProgram() : null;
    if (program) {
      gl.attachShader(program, vs);
      gl.attachShader(program, fs);
      gl.linkProgram(program);
    }
    if (vs) gl.deleteShader(vs);
    if (fs) gl.deleteShader(fs);
    if (!program || !gl.getProgramParameter(program, gl.LINK_STATUS)) {
      if (program) gl.deleteProgram(program);
      return null;
    }
    const triangle = gl.createBuffer();
    if (!triangle) { gl.deleteProgram(program); return null; }
    gl.bindBuffer(gl.ARRAY_BUFFER, triangle);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1,3,-1,-1,3]), gl.STATIC_DRAW);
    const attrib = gl.getAttribLocation(program, 'aPosition');
    const size = gl.getUniformLocation(program, 'uSize');
    const phase = gl.getUniformLocation(program, 'uPhase');
    const bands = gl.getUniformLocation(program, 'uBands');
    let disposed = false;
    const band = n => Math.min(1, Math.max(0, Number(n) || 0));
    return {
      draw(time, levels) {
        const w=gl.drawingBufferWidth, h=gl.drawingBufferHeight;
        if (disposed || !w || !h || gl.isContextLost()) return;
        gl.viewport(0,0,w,h);
        gl.useProgram(program);
        gl.bindBuffer(gl.ARRAY_BUFFER,triangle);
        gl.enableVertexAttribArray(attrib);
        gl.vertexAttribPointer(attrib,2,gl.FLOAT,false,0,0);
        gl.uniform2f(size,w,h);
        const seconds=Number.isFinite(time)?time:0;
        gl.uniform1f(phase, ((seconds%48+48)%48)*Math.PI/24);
        gl.uniform3f(bands,band(levels?.[0]),band(levels?.[1]),band(levels?.[2]));
        gl.drawArrays(gl.TRIANGLES,0,3);
      },
      dispose() {
        if(disposed) return;
        disposed=true;
        gl.deleteBuffer(triangle);
        gl.deleteProgram(program);
      }
    };
  };
})();
