/* Illustrated orthographic renderer with per-pixel depth, including outlines. */
const COLORS={paper:'#F7EEDC',floor:'#E8DDC6',ink:'#392F26',shirt:'#71815B',shirtSide:'#596947',skin:'#C98E68',skinSide:'#AE7659',pants:'#54616A',hair:'#47372D',shoe:'#F1E8D4',metal:'#8A9388',machine:'#657366',pad:'#596947',grip:'#4A4C43',mat:'#B7B591',wood:'#B58960',wall:'#C9C8B1',cable:'#545E53',band:'#BB654E',rope:'#956D48',assistance:'#8D9E74',console:'#53686C',ball:'#99A36E'};
const cameraCache=new Map(),rasterCache=new WeakMap();
const CAMERA_PRESETS={'front-iso':{azimuth:45,elevation:35.264},'rear-iso':{azimuth:135,elevation:35.264},front:{azimuth:0,elevation:15},side:{azimuth:90,elevation:14}};
function cameraSpec(e,p,override='exercise'){return CAMERA_PRESETS[override==='exercise'?e.viewPreset:override]||{azimuth:p.view,elevation:e.viewElevation??18};}
function cameraAxes(spec){const a=spec.azimuth*RAD,b=spec.elevation*RAD,c=Math.cos(a),s=Math.sin(a),cb=Math.cos(b),sb=Math.sin(b);return{horizontal:[c,s,0],vertical:[-s*sb,c*sb,-cb],depth:[-s*cb,c*cb,sb]};}
function frameCamera(e,override='exercise'){
 const key=e.id+'|'+override;if(cameraCache.has(key))return cameraCache.get(key);
 let minU=Infinity,maxU=-Infinity,minV=Infinity,maxV=-Infinity,axes;
 for(let i=0;i<=48;i++){
  const p=MOTIONS[e.motion](e,e.hold?0:i/48);axes=cameraAxes(cameraSpec(e,p,override));
  const include=(v,r=0)=>{const d=V.sub(v,p.center),u=V.dot(axes.horizontal,d),w=V.dot(axes.vertical,d);minU=Math.min(minU,u-r);maxU=Math.max(maxU,u+r);minV=Math.min(minV,w-r);maxV=Math.max(maxV,w+r);};
  for(const v of Object.values(p.j))include(v,6);for(const v of p.spine)include(v,15);include(p.head,17);
  for(const o of p.objects){if(o.color==='mat')continue;if(o.points)for(const v of o.points)include(v,(o.width||1)/2+1);if(!o.center)continue;
   if(o.type==='box'){const b=o.basis||{right:[1,0,0],forward:[0,1,0],up:[0,0,1]};for(const x of [-1,1])for(const y of [-1,1])for(const z of [-1,1])include(V.add(o.center,V.add(V.mul(b.right,o.size[0]/2*x),V.add(V.mul(b.forward,o.size[1]/2*y),V.mul(b.up,o.size[2]/2*z)))),1);}
   else if(o.type==='bar'){include(V.add(o.center,V.mul(o.axis,o.half)),11);include(V.add(o.center,V.mul(o.axis,-o.half)),11);}else include(o.center,o.type==='kettlebell'?19:o.radius||10);
  }
 }
 const scale=Math.min(2.35,284/(maxU-minU),204/(maxV-minV)),result={scale,x:160-(minU+maxU)/2*scale,y:119-(minV+maxV)/2*scale,axes};cameraCache.set(key,result);return result;
}
function projectPoint(p,v){const c=p.camera,d=V.sub(v,p.center);return[c.x+c.scale*V.dot(c.axes.horizontal,d),c.y+c.scale*V.dot(c.axes.vertical,d),V.dot(c.axes.depth,d)];}
function tint(hex,f){if(!/^#[0-9a-f]{6}$/i.test(hex))return hex;return '#'+[1,3,5].map(i=>Math.round(Math.min(255,parseInt(hex.slice(i,i+2),16)*f)).toString(16).padStart(2,'0')).join('');}
function pixelColor(hex){const n=parseInt(hex.slice(1),16);return(0xff000000|((n&255)<<16)|(n&0xff00)|((n>>>16)&255))>>>0;}
class DepthRaster{
 constructor(ctx){this.ctx=ctx;this.width=ctx.canvas.width;this.height=ctx.canvas.height;this.sx=this.width/320;this.sy=this.height/240;this.image=ctx.createImageData(this.width,this.height);this.pixels=new Uint32Array(this.image.data.buffer);this.z=new Float32Array(this.width*this.height);this.colorCache=new Map();this.lastStats={};}
 color(hex){if(!this.colorCache.has(hex))this.colorCache.set(hex,pixelColor(hex));return this.colorCache.get(hex);}
 clear(hex){this.pixels.fill(this.color(hex));this.z.fill(-Infinity);this.lastStats={triangles:0,segments:0,depthRejected:0};}
 triangle(a,b,c,hex,bias=0){
  this.lastStats.triangles++;
  const ax=a[0]*this.sx,ay=a[1]*this.sy,bx=b[0]*this.sx,by=b[1]*this.sy,cx=c[0]*this.sx,cy=c[1]*this.sy,area=(bx-ax)*(cy-ay)-(by-ay)*(cx-ax);if(Math.abs(area)<1e-9)return;
  const loX=Math.max(0,Math.floor(Math.min(ax,bx,cx))),hiX=Math.min(this.width-1,Math.ceil(Math.max(ax,bx,cx))),loY=Math.max(0,Math.floor(Math.min(ay,by,cy))),hiY=Math.min(this.height-1,Math.ceil(Math.max(ay,by,cy))),inv=1/area,color=this.color(hex),w=this.width;
  for(let y=loY;y<=hiY;y++)for(let x=loX;x<=hiX;x++){
   const px=x+.5,py=y+.5,u=((bx-px)*(cy-py)-(by-py)*(cx-px))*inv,v=((cx-px)*(ay-py)-(cy-py)*(ax-px))*inv,t=1-u-v;if(u<-.00001||v<-.00001||t<-.00001)continue;
   const z=u*a[2]+v*b[2]+t*c[2]+bias,idx=y*w+x;if(z>=this.z[idx]-.00001){this.z[idx]=z;this.pixels[idx]=color}else this.lastStats.depthRejected++;
  }
 }
 segment(a,b,width,hex,scale,{outline=false,bias=0,flat=false}={}){
  this.lastStats.segments++;
  const ax=a[0]*this.sx,ay=a[1]*this.sy,bx=b[0]*this.sx,by=b[1]*this.sy,dx=bx-ax,dy=by-ay,len=dx*dx+dy*dy,r=Math.max(.55,width*scale*this.sx/2),r2=r*r;
  const loX=Math.max(0,Math.floor(Math.min(ax,bx)-r)),hiX=Math.min(this.width-1,Math.ceil(Math.max(ax,bx)+r)),loY=Math.max(0,Math.floor(Math.min(ay,by)-r)),hiY=Math.min(this.height-1,Math.ceil(Math.max(ay,by)+r)),color=this.color(hex),ink=this.color(COLORS.ink),inner=Math.max(0,r-.55*this.sx),inner2=inner*inner,worldPerPixel=1/(scale*this.sx);
  for(let y=loY;y<=hiY;y++)for(let x=loX;x<=hiX;x++){
   const t=len?Math.max(0,Math.min(1,((x+.5-ax)*dx+(y+.5-ay)*dy)/len)):0,ex=x+.5-ax-t*dx,ey=y+.5-ay-t*dy,d2=ex*ex+ey*ey;if(d2>r2)continue;
   const z=a[2]+t*(b[2]-a[2])+(flat?0:Math.sqrt(Math.max(0,r2-d2))*worldPerPixel)+bias,idx=y*this.width+x;
   if(z>=this.z[idx]-.00001){this.z[idx]=z;this.pixels[idx]=outline&&d2>inner2?ink:color}else this.lastStats.depthRejected++;
  }
 }
 finish(){this.ctx.putImageData(this.image,0,0);}
}
function drawExercise(ctx,e,p,person='male',override='exercise'){
 p.camera=frameCamera(e,override);p.scale=p.camera.scale;
 let raster=rasterCache.get(ctx);if(!raster||raster.width!==ctx.canvas.width||raster.height!==ctx.canvas.height){raster=new DepthRaster(ctx);rasterCache.set(ctx,raster)}
 const pal={...COLORS,...(person==='female'?{shirt:'#B16F59',shirtSide:'#915646',pants:'#4D505D',hair:'#6A4435'}:{})},edges=[],color=k=>pal[k]||k,project=v=>projectPoint(p,v);raster.clear(pal.paper);
 function poly(points,fill,stroke=true){const ps=points.map(project);for(let i=1;i<ps.length-1;i++)raster.triangle(ps[0],ps[i],ps[i+1],color(fill));if(stroke)for(let i=0;i<ps.length;i++)edges.push([ps[i],ps[(i+1)%ps.length]]);}
 function line(points,fill,width,outline=false){for(let i=1;i<points.length;i++)raster.segment(project(points[i-1]),project(points[i]),width,color(fill),p.scale,{outline});}
 function sphere(center,r,fill,outline=true){const a=project(center);raster.segment(a,a,r*2,color(fill),p.scale,{outline});}
 function box(center,size,fill,basis=null,stroke=true){
  const b=basis||{right:[1,0,0],forward:[0,1,0],up:[0,0,1]},[w,d,h]=size,vs=[];for(const z of [-1,1])for(const y of [-1,1])for(const x of [-1,1])vs.push(V.add(center,V.add(V.mul(b.right,x*w/2),V.add(V.mul(b.forward,y*d/2),V.mul(b.up,z*h/2)))));
  for(const [face,shade]of [[[0,1,3,2],.86],[[4,6,7,5],1.08],[[0,4,5,1],.8],[[2,3,7,6],1],[[0,2,6,4],.88],[[1,5,7,3],.96]])poly(face.map(i=>vs[i]),tint(color(fill),shade),stroke);
 }
 function cylinder(center,axis,length,radius,fill,segments=16){
  const a=V.unit(axis),f=V.unit(Math.abs(a[2])<.8?V.cross([0,0,1],a):V.cross([0,1,0],a)),u=V.unit(V.cross(a,f)),rings=[-1,1].map(s=>Array.from({length:segments},(_,i)=>V.add(V.add(center,V.mul(a,s*length/2)),V.add(V.mul(f,radius*Math.cos(i/segments*Math.PI*2)),V.mul(u,radius*Math.sin(i/segments*Math.PI*2))))));poly([...rings[0]].reverse(),tint(color(fill),.86));poly(rings[1],fill);
  for(let i=0;i<segments;i++){const n=(i+1)%segments;poly([rings[0][i],rings[0][n],rings[1][n],rings[1][i]],tint(color(fill),.86+.14*Math.cos((i+.5)/segments*Math.PI*2)),false);}
 }
 function ring(center,r,axis=[1,0,0],fill='metal',width=2){const f=V.unit(Math.abs(axis[2])<.8?V.cross([0,0,1],axis):[1,0,0]),u=V.unit(V.cross(axis,f)),pts=[];for(let k=0;k<=40;k++){const a=k/40*Math.PI*2;pts.push(V.add(center,V.add(V.mul(f,r*Math.cos(a)),V.mul(u,r*Math.sin(a)))))}line(pts,fill,width);}
 poly([[-160,-150,-3],[160,-150,-3],[160,150,-3],[-160,150,-3]].map(v=>V.add(v,p.center)),'floor',false);
 for(const o of p.objects){
  if(o.type==='line')line(o.points,o.color,o.width);
  if(o.type==='box')box(o.center,o.size,o.color,o.basis);
  if(o.type==='bar'){const end=x=>V.add(o.center,V.mul(o.axis,x));line([end(-o.half),end(o.half)],'metal',2.5);for(const s of [-1,1])cylinder(end(s*(o.half-7)),o.axis,4,9,'grip');}
  if(o.type==='dumbbell'){const a=V.unit(o.axis);line([V.add(o.center,V.mul(a,-8)),V.add(o.center,V.mul(a,8))],'metal',2.5);for(const s of [-1,1])cylinder(V.add(o.center,V.mul(a,s*6)),a,3.5,4.7,'grip',8);}
  if(o.type==='kettlebell'){ring(V.add(o.center,[0,0,-2]),5,[0,1,0],'grip',2);sphere(V.add(o.center,[0,0,-11]),7,'ball');}
  if(o.type==='pulley'){cylinder(o.center,[1,0,0],2.5,3.5,'grip',12);sphere(o.center,1.2,'metal',false);}
  if(o.type==='handle')line([V.add(o.center,[-3,0,0]),V.add(o.center,[3,0,0])],'grip',3);
  if(o.type==='ball')sphere(o.center,o.radius,'ball');
  if(o.type==='wheel'){ring(o.center,o.radius,o.axis,'grip',2.5);sphere(o.center,2.5,'metal',false);const f=V.unit(Math.abs(o.axis[2])<.8?V.cross([0,0,1],o.axis):[1,0,0]),u=V.cross(o.axis,f);for(const v of [V.mul(f,o.radius),V.mul(u,o.radius)])line([V.sub(o.center,v),V.add(o.center,v)],'metal',1.2);}
  if(o.type==='cylinder')cylinder(o.center,o.axis,o.length,o.radius,o.color);
  if(o.type==='roller')cylinder(o.center,[1,0,0],o.length,o.radius,'mat');
  if(o.type==='cuff')box(o.center,[9,5,6],'band');
  if(o.type==='hand')line([o.center,V.add(o.center,V.mul(o.direction,6))],'skin',4,true);
 }
 // Sleeve and skin have actual enclosing radii, not independently sorted outlines.
 for(const s of [-1,1]){const k=p.j[s<0?'lk':'rk'],a=p.j[s<0?'la':'ra'];if(k&&a)line([socket(p,s,false),k,a],'pants',8.2,true);}
 const right=p.right,forward=p.forward;box(V.add(p.hip,V.mul(p.up,-2.5)),[20,11,7],'pants',{right:p.hipRight,forward:p.forward,up:p.up},false);
 for(let i=1;i<p.spine.length;i++){
  const a=p.spine[i-1],b=p.spine[i],up=V.unit(V.sub(b,a)),f=V.unit(V.sub(forward,V.mul(up,V.dot(forward,up)))),r=V.unit(V.sub(right,V.mul(up,V.dot(right,up)))),w0=mix(20,27,(i-1)/(p.spine.length-1)),w1=mix(20,27,i/(p.spine.length-1)),corners=(pt,w)=>[V.add(pt,V.add(V.mul(r,-w/2),V.mul(f,-5))),V.add(pt,V.add(V.mul(r,w/2),V.mul(f,-5))),V.add(pt,V.add(V.mul(r,w/2),V.mul(f,5))),V.add(pt,V.add(V.mul(r,-w/2),V.mul(f,5)))],lo=corners(a,w0),hi=corners(b,w1);
  for(let j=0;j<4;j++)poly([lo[j],lo[(j+1)%4],hi[(j+1)%4],hi[j]],j===2?'shirt':'shirtSide',false);if(i===p.spine.length-1)poly(hi,'shirt',false);for(const j of [0,1,2,3])edges.push([project(lo[j]),project(hi[j])]);
 }
 for(const s of [-1,1]){const o=socket(p,s),j=p.j[s<0?'le':'re'],h=p.j[s<0?'lh':'rh'];if(!j||!h)continue;line([o,j,h],'skin',5.8,true);line([o,V.mix(o,j,.42)],'shirt',8.3,true);/*__CUSTOM_HAND_BEGIN__*/if(p.handStyle!=='custom'){/*__CUSTOM_HAND_END__*/box(h,[4.2,4.2,4.2],'skin');if(p.grip)box(V.add(h,p.grip==='neutral'?[s*2.6,0,2]:[s*1.8,p.grip==='supinated'?-2.8:2.8,0]),[2,2,3],'skin',null,false);/*__CUSTOM_HAND_BEGIN__*/}/*__CUSTOM_HAND_END__*/}
 for(const f of p.feet){const basis={right:f.right,forward:f.forward,up:f.up},center=V.add(f.ankle,V.add(V.mul(f.forward,2),V.mul(f.up,-1)));box(center,[8,14,6],'shoe',basis);box(V.add(center,V.mul(f.up,-2.7)),[8.4,14.4,1.2],'ink',basis,false);}
 const hu=p.headUp||p.up,hr=p.headRight||p.right,hf=V.unit(V.sub(p.forward,V.mul(hu,V.dot(p.forward,hu)))),hb={right:hr,forward:hf,up:hu},hc=p.head;line([p.shoulder,V.sub(hc,V.mul(hu,6))],'skin',5.5,true);box(hc,[17,14,18],'skin',hb);box(V.add(hc,V.mul(hu,8)),[19,16,5],'hair',hb);box(V.add(hc,V.mul(hf,-6)),[18,3.4,17],'hair',hb);
 if(person==='female'){box(V.add(hc,V.add(V.mul(hf,-10),V.mul(hu,-1))),[8,7,16],'hair',hb);box(V.add(hc,V.mul(hr,-8)),[3,14,18],'hair',hb);}
 // Face decals test depth against the face at each pixel, never its average depth.
 for(const s of [-1,1])box(V.add(hc,V.add(V.mul(hr,s*3.5),V.add(V.mul(hf,7.3),V.mul(hu,2)))),[1.8,.45,2.7],'ink',hb,false);box(V.add(hc,V.mul(hf,7.9)),[2.3,2.1,2.4],'skin',hb,false);
 for(const [a,b]of edges)raster.segment(a,b,.5/p.scale,pal.ink,p.scale,{flat:true,bias:.045});raster.finish();return p;
}
function renderExercise(ctx,e,t,person='male',override='exercise'){return drawExercise(ctx,e,sampleExercise(e,t),person,override);}
