/* Original 3D coordinate studies. Projection changes apparent limb lengths naturally.
   Contact IK uses an explicit pole direction, never nearest-of-two elbow/knee hints. */
const V={add:(a,b)=>a.map((v,i)=>v+b[i]),sub:(a,b)=>a.map((v,i)=>v-b[i]),mul:(a,s)=>a.map(v=>v*s),dot:(a,b)=>a.reduce((s,v,i)=>s+v*b[i],0),cross:(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]],len:a=>Math.hypot(...a),unit:a=>{const n=Math.hypot(...a)||1;return a.map(v=>v/n)},mix:(a,b,t)=>a.map((v,i)=>v+(b[i]-v)*t)};
const RAD=Math.PI/180,clamp=(x,a=0,b=1)=>Math.max(a,Math.min(b,x)),ease=x=>{x=clamp(x);return x*x*(3-2*x)},mix=(a,b,t)=>a+(b-a)*t;
const rep=t=>(1-Math.cos(2*Math.PI*t))/2, wave=t=>Math.sin(2*Math.PI*t), rotZ=(a,t)=>[a[0]*Math.cos(t)-a[1]*Math.sin(t),a[0]*Math.sin(t)+a[1]*Math.cos(t),a[2]];
function keyValue(t,keys){t=clamp(t);for(let i=1;i<keys.length;i++)if(t<=keys[i][0]){const a=keys[i-1],b=keys[i];return Array.isArray(a[1])?V.mix(a[1],b[1],ease((t-a[0])/(b[0]-a[0]))):mix(a[1],b[1],ease((t-a[0])/(b[0]-a[0])))}return keys[keys.length-1][1]}
function ik(o,target,a,b,pole){const d0=V.len(V.sub(target,o)),d=clamp(d0,Math.abs(a-b)+.00001,a+b-.00001),u=V.unit(V.sub(target,o));let bend=V.sub(pole,V.mul(u,V.dot(pole,u)));if(V.len(bend)<.00001)bend=V.cross(u,Math.abs(u[0])<.9?[1,0,0]:[0,1,0]);bend=V.unit(bend);const along=(a*a-b*b+d*d)/(2*d),h=Math.sqrt(Math.max(0,a*a-along*along));return{joint:V.add(o,V.add(V.mul(u,along),V.mul(bend,h))),end:V.add(o,V.mul(u,d)),reachError:Math.max(0,d0-a-b)};}
function model(hip=[0,0,61],up=[0,0,1],forward=[0,1,0],right=[1,0,0]){
 up=V.unit(up);forward=V.unit(V.sub(forward,V.mul(up,V.dot(forward,up))));
 const p={j:{},hip,up,forward,right:V.unit(right),hipRight:[1,0,0],objects:[],feet:[],contacts:[],errors:[],view:55,scale:1.47,center:[0,0,0]};
 p.spine=[hip,V.add(hip,V.mul(p.up,12)),V.add(hip,V.mul(p.up,24)),V.add(hip,V.mul(p.up,36))];p.shoulder=p.spine[3];p.head=V.add(p.shoulder,V.add(V.mul(p.up,15),V.mul(p.forward,3)));return p;
}
function setSpine(p,points){p.spine=points;p.hip=points[0];p.shoulder=points.at(-1);p.up=V.unit(V.sub(points.at(-1),points.at(-2)));p.head=V.add(p.shoulder,V.add(V.mul(p.up,15),V.mul(p.forward,3)));}
function socket(p,s,arm=true){if(arm&&p.armSockets?.[s])return p.armSockets[s];return V.add(arm?p.shoulder:p.hip,V.mul(arm?p.right:p.hipRight,s*(arm?13:6)))}
function arm(p,s,end,pole=[0,-1,0]){const o=socket(p,s),q=ik(o,end,24,23,pole);p.j[s<0?'le':'re']=q.joint;p.j[s<0?'lh':'rh']=q.end;if(q.reachError>.2)p.errors.push({limb:s<0?'left arm':'right arm',error:q.reachError});return q.end;}
function armFK(p,s,upper,lower){const o=socket(p,s),j=V.add(o,V.mul(V.unit(upper),24)),end=V.add(j,V.mul(V.unit(lower),23));p.j[s<0?'le':'re']=j;p.j[s<0?'lh':'rh']=end;return end;}
function hangArms(p){for(const s of [-1,1])armFK(p,s,[s*.08,0,-1],[s*.03,0,-1]);}
function foot(p,s,ankle,pitch=0,heading=[0,1,0],support=false){const f=V.unit([heading[0]*Math.cos(pitch),heading[1]*Math.cos(pitch),-Math.sin(pitch)]),u=[heading[0]*Math.sin(pitch),heading[1]*Math.sin(pitch),Math.cos(pitch)],r=V.unit(V.cross(f,u));p.feet.push({s,ankle,forward:f,up:u,right:r,support});if(support)p.contacts.push({kind:'foot',point:V.add(ankle,V.add(V.mul(f,9),V.mul(u,-4))),height:0});}
function leg(p,s,end,pole=[0,1,0],pitch=0,support=false,heading=[0,1,0]){const o=socket(p,s,false),q=ik(o,end,29,29,pole);p.j[s<0?'lk':'rk']=q.joint;p.j[s<0?'la':'ra']=q.end;if(q.reachError>.2)p.errors.push({limb:s<0?'left leg':'right leg',error:q.reachError});foot(p,s,q.end,pitch,heading,support);return q.end;}
function legFK(p,s,upper,lower,pitch=0,heading=[0,1,0]){const o=socket(p,s,false),j=V.add(o,V.mul(V.unit(upper),29)),end=V.add(j,V.mul(V.unit(lower),29));p.j[s<0?'lk':'rk']=j;p.j[s<0?'la':'ra']=end;foot(p,s,end,pitch,heading);return end;}
function plantedLegs(p,width=11,y=0){for(const s of [-1,1])leg(p,s,[s*width,y,4],[0,1,0],0,true);}
function shape(p,type,data){p.objects.push({type,...data});}
function pipe(p,points,width=3,color='metal'){shape(p,'line',{points,width,color});}
function block(p,center,size,color='pad',basis=null){shape(p,'box',{center,size,color,basis});}
function mat(p){block(p,[0,8,-1],[52,145,1.5],'mat');}
function bench(p,a=[0,-8,32],b=[0,63,32],width=29){pipe(p,[[0,a[1],5],a],4);pipe(p,[[0,b[1]-8,5],[0,b[1]-8,b[2]]],4);block(p,V.mix(a,b,.5),[width,V.len(V.sub(b,a)),4],'pad',{right:[1,0,0],forward:V.unit(V.sub(b,a)),up:V.unit(V.cross([1,0,0],V.sub(b,a)))});pipe(p,[[-18,a[1],2],[18,a[1],2]],4);pipe(p,[[-18,b[1]-8,2],[18,b[1]-8,2]],4);}
function seat(p,y=0,z=33,back=true,width=29){block(p,[0,y,z],[width,30,4],'pad');pipe(p,[[0,y,3],[0,y,z-2]],4);pipe(p,[[-20,y,2],[20,y,2]],4);if(back)block(p,[0,y-13,z+23],[width,4,42],'pad');}
function bar(p,center,axis=[1,0,0],half=43){shape(p,'bar',{center,axis:V.unit(axis),half});}
function dumbbell(p,point,axis=[1,0,0]){shape(p,'dumbbell',{center:point,axis:V.unit(axis)});}
function kb(p,point){shape(p,'kettlebell',{center:point});}
function loads(p,e,{one=false,axis=[1,0,0],at=null}={}){const points=at?[at]:one?[p.j.rh]:[p.j.lh,p.j.rh];if(e.equipment==='dumbbell')for(const h of points)dumbbell(p,h,axis);if(e.equipment==='kettlebell')kb(p,at||V.mix(p.j.lh,p.j.rh,.5));if(e.equipment==='barbell')bar(p,at||V.mix(p.j.lh,p.j.rh,.5),axis);}
function cable(p,origin,end,color='cable',handle=true){pipe(p,[origin,end],1.3,color);if(handle)shape(p,'handle',{center:end});}
function station(p,origin){const base=[origin[0],origin[1],2];pipe(p,[base,[origin[0],origin[1],150]],4);block(p,[origin[0],origin[1]-5,45],[13,11,67],'machine');pipe(p,[V.add(base,[-16,-6,0]),V.add(base,[16,10,0])],5);shape(p,'pulley',{center:origin});}
function bandFeet(p){for(const s of [-1,1])cable(p,[s*11,0,1],p.j[s<0?'lh':'rh'],'band');}
function rail(p,x,y,top=140){pipe(p,[[x,y,2],[x,y,top]],3);pipe(p,[[x-7,y-7,2],[x+7,y+7,2]],4);}
function supine(z=6,y=0){const p=model([0,y,z],[0,1,0],[0,0,1]);p.view=65;p.scale=1.5;return p;}
function bentSupineLegs(p,width=11,y=-30){for(const s of [-1,1])leg(p,s,[s*width,y,4],[0,0,1],0,true,[0,-1,0]);}
function groundArm(p,s,y=-4){arm(p,s,[s*17,y,4],[s*.6,0,1]);}
function articulatedCrunch(p,q){let a=p.hip;const spine=[a];for(const angle of [3*q,22*q,46*q]){a=V.add(a,[0,12*Math.cos(angle*RAD),12*Math.sin(angle*RAD)]);spine.push(a)}p.forward=[0,-Math.sin(46*q*RAD),Math.cos(46*q*RAD)];setSpine(p,spine);}

function benchPress(e,t){const n=e.number,q=rep(t),inc=[2,81].includes(n),floor=n===94,a=inc?28*RAD:0,z=floor?6:39;
 const p=model([0,0,z],[0,Math.cos(a),Math.sin(a)],[0,-Math.sin(a),Math.cos(a)]);p.view=62;p.scale=1.46;
 if(floor)mat(p);else bench(p,V.add(p.hip,V.add(V.mul(p.up,-10),V.mul(p.forward,-7))),V.add(p.hip,V.add(V.mul(p.up,67),V.mul(p.forward,-7))));
 bentSupineLegs(p,12,-29);const span=n===12?12:21;
 for(const s of [-1,1]){const low=V.add(p.shoulder,V.add(V.mul(p.up,-8),V.mul(p.forward,floor?17:9))),high=[s*span,p.shoulder[1]-7,p.shoulder[2]+44];arm(p,s,V.mix(high,[s*span,low[1],low[2]],q),[s,-.25,-.45]);}
 loads(p,e);return p;
}
function overheadPress(e,t){
 const n=e.number,q=rep(t),machine=n===128,p=model(machine?[0,0,36]:[0,0,61]);p.view=22;
 if(machine){seat(p,0,28);for(const side of [-1,1]){rail(p,side*37,-12);pipe(p,[[side*37,-12,120],[side*25,6,118]],3);leg(p,side,[side*13,30,4],[0,1,0],0,true);}}else plantedLegs(p);
 for(const side of [-1,1]){
  const span=n===3?25:15,clearance=n===3?15:8,barY=mix(clearance,3,ease((q-.62)/.38)),rise=Math.sqrt(46.9**2-(span-13)**2-3**2),start=[side*(n===80?10:25),n===80?15:clearance,p.shoulder[2]+1],end=[side*span,3,p.shoulder[2]+rise],angle=(-45+80*q)*RAD,pivot=[side*25,-22,97.5];
  const target=machine?V.add(pivot,[0,34*Math.cos(angle),34*Math.sin(angle)]):n===3?[side*25,barY,mix(start[2],end[2],q)]:V.mix(start,end,q);
  arm(p,side,target,[side,0,-.35]);
  if(machine){pipe(p,[[side*37,-12,97.5],pivot,p.j[side<0?'lh':'rh']],3);shape(p,'handle',{center:p.j[side<0?'lh':'rh']});}
 }
 if(n===70)bandFeet(p);else if(!machine)loads(p,e,{axis:n===80?[Math.cos(q*Math.PI/2),Math.sin(q*Math.PI/2),0]:[1,0,0]});if(n===3)p.grip='pronated';return p;
}

function pushup(e,t){const n=e.number,q=rep(t),pike=n===60,wall=n===124,knees=n===123,inc=n===95,decline=n===126,handY=38,handZ=wall?72:inc?40:3;
 if(wall){const p=model([0,-22,52],[0,.18,.984],[0,1,0]);p.view=72;block(p,[0,35,63],[65,4,126],'wall');plantedLegs(p,11,-24);const sh=[0,3+15*q,88-7*q];setSpine(p,[p.hip,V.mix(p.hip,sh,1/3),V.mix(p.hip,sh,2/3),sh]);for(const s of [-1,1])arm(p,s,[s*19,33,80],[0,-1,-1]);return p;}
 const pitch=1.08,ankleZ=(decline?40:0)+9*Math.sin(pitch)+4*Math.cos(pitch),ankleY=(pike?-33:-62)-9*Math.cos(pitch)+4*Math.sin(pitch);
 let hip,up,hy=25,hz=3;
 if(pike){hip=[0,-8+10*q,60-5*q];const a=(48+12*q)*RAD;up=[0,Math.cos(a),-Math.sin(a)];hy=51;}
 else if(knees){const a=(44-24*q)*RAD;up=[0,Math.cos(a),Math.sin(a)];hip=V.add([0,-25,4],V.mul(up,29));}
 else{hz=inc?43:3;const shZ=hz+46.3-24*q,a=Math.asin((shZ-ankleZ)/94);up=[0,Math.cos(a),Math.sin(a)];hip=V.add([0,ankleY,ankleZ],V.mul(up,58));if(inc)hy=-10;if(decline)hy=31;}
 const p=model(hip,up,[0,0,-1]);p.view=75;p.scale=1.48;mat(p);
 if(inc)block(p,[0,hy,20],[55,30,40],'pad');if(decline)block(p,[0,-62,20],[48,25,40],'pad');
 for(const s of [-1,1]){arm(p,s,[s*(n===125?8:18),hy,hz],[0,-1,0]);
  if(knees){const k=[s*6,-25,4];p.j[s<0?'lk':'rk']=k;p.j[s<0?'la':'ra']=[s*6,-51,17];foot(p,s,p.j[s<0?'la':'ra'],.4,[0,-1,0]);p.contacts.push({kind:'knee',point:k,height:4});}
  else if(pike)leg(p,s,[s*6,ankleY,ankleZ],[0,-1,-.2],pitch);
  else legFK(p,s,V.mul(up,-1),V.mul(up,-1),pitch);
 }
 return p;
}
function dip(e,t){const q=rep(t),p=model([0,0,70-23*q]);p.view=30;p.scale=1.32;for(const s of [-1,1]){arm(p,s,[s*24,0,61],[0,-1,0]);pipe(p,[[s*24,-15,61],[s*24,18,61]],4);rail(p,s*24,-15,61);legFK(p,s,[0,-.3,-1],[0,-1,.3],.3);}
 if(e.number===129){const k=V.mix(p.j.lk,p.j.rk,.5);block(p,V.add(k,[0,0,-5]),[30,22,5],'assistance');pipe(p,[[0,-20,3],[0,-20,k[2]]],4);}
 return p;
}
function chestFly(e,t){const n=e.number,q=rep(t),sup=n===97,p=sup?supine(39):model(n===130?[0,0,35]:[0,0,61]);p.view=sup?38:25;
 if(n===7){p.view=0;plantedLegs(p,13);for(const side of [-1,1]){arm(p,side,V.mix([side*54,8,114],[side*4,40,75],q),[side,.1,-.2]);const a=[side*68,-20,126];station(p,a);cable(p,a,p.j[side<0?'lh':'rh']);}return p;}

 if(sup){bench(p);bentSupineLegs(p);}else if(n===130){seat(p,0,28);plantedLegs(p,12,25);}else plantedLegs(p,13);
 for(const s of [-1,1]){const open=70*(1-q)*RAD,forward=V.add(V.mul(p.forward,Math.cos(open)),V.mul(p.right,s*Math.sin(open)));armFK(p,s,V.add(V.mul(forward,.95),V.mul(p.up,-.2)),V.add(forward,V.mul(p.up,.15)));const h=p.j[s<0?'lh':'rh'];
  if(n===7){const a=[s*65,-16,110];station(p,a);cable(p,a,h);}if(n===130){const origin=[s*35,-10,85];pipe(p,[origin,p.j[s<0?'le':'re'],h],3);block(p,p.j[s<0?'le':'re'],[8,5,16],'pad');rail(p,s*35,-10,85);}
 }if(sup)loads(p,e);return p;
}
function raise(e,t){const n=e.number,q=rep(t),rear=[23,137].includes(n),front=n===9,p=model(rear?[0,-6,55]:[0,0,61],rear?[0,.94,.34]:[0,0,1],rear?[0,.34,-.94]:[0,1,0]);p.view=rear?48:front?60:20;
 if(n===137){const p=model([0,0,35],[0,.1,.995]);p.view=35;seat(p,0,28,false);plantedLegs(p,12,28);block(p,[0,10,54],[26,5,35],'pad');for(const s of [-1,1]){const a=80*q*RAD,dir=V.add(V.mul(p.forward,Math.cos(a)),V.mul(p.right,s*Math.sin(a)));armFK(p,s,dir,dir);const h=p.j[s<0?'lh':'rh'];rail(p,s*37,17,111);pipe(p,[[s*37,17,111],h],3);pipe(p,[V.add(h,[0,0,-6]),V.add(h,[0,0,6])],3,'grip');}return p;}
 plantedLegs(p);
 for(const s of [-1,1]){const a=(8+79*q)*RAD,dir=front?[0,Math.sin(a),-Math.cos(a)]:rear?V.add(V.mul(p.right,s*Math.sin(a)),V.mul(p.forward,Math.cos(a))):[s*Math.sin(a),0,-Math.cos(a)];armFK(p,s,dir,V.add(dir,V.mul(p.up,-.1)));}
 if(n===76)bandFeet(p);else if(n===131){for(const s of [-1,1]){const a=[-65,-12,5];station(p,a);cable(p,a,p.j[s<0?'lh':'rh']);}}else if(n===137){block(p,V.add(p.shoulder,V.mul(p.forward,5)),[24,5,25],'pad');seat(p,-6,28,false);for(const s of [-1,1]){pipe(p,[[s*36,20,99],p.j[s<0?'lh':'rh']],3);rail(p,s*36,20,99);}}else loads(p,e);return p;
}
function pushdown(e,t){const q=rep(t),p=model();p.view=60;plantedLegs(p);for(const s of [-1,1]){const o=socket(p,s),el=V.add(o,[0,1,-24]),a=(100-90*q)*RAD;p.j[s<0?'le':'re']=el;p.j[s<0?'lh':'rh']=V.add(el,[0,23*Math.sin(a),-23*Math.cos(a)]);}
 const a=[0,40,145];station(p,a);const h=V.mix(p.j.lh,p.j.rh,.5);cable(p,a,h,e.number===75?'band':'cable');pipe(p,[p.j.lh,p.j.rh],3,'grip');return p;
}
function skullcrusher(e,t){const q=rep(t),p=supine(39);bench(p);bentSupineLegs(p);for(const s of [-1,1]){const a=q*100*RAD;armFK(p,s,[0,0,1],[0,Math.sin(a),Math.cos(a)]);}loads(p,e);return p;}
function pullup(e,t){
 const n=e.number,q=rep(t),span=n===14?23:27,handY=15,hangShoulder=144-Math.sqrt(46.9**2-(span-13)**2-handY**2),p=model([0,0,mix(hangShoulder-36,104,q)]);p.view=n===14?30:40;p.scale=1.25;
 for(const side of [-1,1]){arm(p,side,[side*span,handY,144],[side,0,-.1]);if(n===134)legFK(p,side,[0,0,-1],[0,-1,0],0,[0,-1,0]);else legFK(p,side,[0,-.15,-1],[0,-.35,-1],.15);rail(p,side*50,handY,150);}pipe(p,[[-50,handY,144],[50,handY,144]],4,'grip');
 if(n===134){block(p,V.add(V.mix(p.j.lk,p.j.rk,.5),[0,0,-5]),[30,24,5],'assistance');rail(p,0,-18,142);}if(n===135)cable(p,[0,handY,144],V.mix(p.j.la,p.j.ra,.5),'band',false);p.grip=n===14?'supinated':'pronated';return p;
}

function pulldown(e,t){
 const n=e.number,q=rep(t),p=model([0,0,35]);p.view=135;bench(p,[0,-40,28],[0,17,28],32);for(const side of [-1,1])leg(p,side,[side*12,32,4],[0,1,0],0,true);
 const span=n===191?14:25,handY=18,top=p.shoulder[2]+Math.sqrt(46.9**2-(span-13)**2-handY**2);
 for(const side of [-1,1]){const active=n!==193||side>0;arm(p,side,active?[side*span,handY,mix(top,69,q)]:[side*17,9,51],[side,0,-.1]);}
 const origin=[0,58,146];station(p,origin);
 if(n===193)cable(p,origin,p.j.rh);
 else if(n===191){p.grip='neutral';const mid=V.mix(p.j.lh,p.j.rh,.5),fork=V.add(mid,[0,0,7]);for(const side of [-1,1]){const h=p.j[side<0?'lh':'rh'];pipe(p,[V.add(h,[0,-5,0]),V.add(h,[0,5,0])],3,'grip');pipe(p,[fork,V.add(h,[0,-5,0])],2.5,'metal');}cable(p,origin,fork,'cable',false);}
 else{pipe(p,[V.add(p.j.lh,[-9,0,2]),p.j.lh,p.j.rh,V.add(p.j.rh,[9,0,2])],3,'grip');cable(p,origin,V.mix(p.j.lh,p.j.rh,.5),n===72?'band':'cable',false);}
 block(p,[0,22,40],[36,10,5],'pad');return p;
}

function row(e,t){const n=e.number,q=rep(t),seated=[18,133,190].includes(n),supported=[17,132].includes(n),p=model(seated?[0,-10,35]:[0,-10,54],seated?[0,.1,.995]:[0,.9,.436]);p.view=60;
 if(seated){seat(p,-10,28,false);for(const s of [-1,1])leg(p,s,[s*12,35.5,11],[0,1,0],-Math.PI/2);block(p,[0,42,11],[38,5,19],'metal');}else plantedLegs(p);
 if(n===17){bench(p,[0,9,43],[0,62,43]);}if(n===132){bench(p,[0,-13,40],[0,51,71],32);const sh=p.shoulder;p.hip[2]=53;block(p,V.add(sh,[0,1,-6]),[28,28,5],'pad');}
 for(const s of [-1,1]){if(n===17&&s<0){arm(p,s,[-13,38,46],[0,0,-1]);continue;}if(n===190&&s<0){armFK(p,s,[0,0,-1],[0,.2,-1]);continue;}const sh=socket(p,s),out=supported?s*9:0;const start=seated?V.add(sh,[0,46.2,-5]):V.add(sh,[out,0,-45.8]),end=V.add(sh,seated?[0,3,-16]:[out,-3,-9]);arm(p,s,V.mix(start,end,q),[s*.08,-1,0]);}
 if([18,133,190].includes(n)){const a=[0,56,38];station(p,a);if(n===190)cable(p,a,p.j.rh);else{pipe(p,[p.j.lh,p.j.rh],3,'grip');cable(p,a,V.mix(p.j.lh,p.j.rh,.5), 'cable',false);}if(n===133){pipe(p,[[0,56,3],[0,-10,3]],5);}}
 else if(n===71){for(const s of [-1,1])cable(p,[0,57,44],p.j[s<0?'lh':'rh'],'band');pipe(p,[[-16,57,0],[16,57,95]],3);}
 else if(n===192){const h=V.mix(p.j.lh,p.j.rh,.5);pipe(p,[[0,65,3],h],4);bar(p,h,[1,0,0],18);block(p,[0,65,3],[20,20,6],'metal');}
 else loads(p,e,{one:n===17});return p;
}
function facePull(e,t){const q=rep(t),p=model();p.view=42;plantedLegs(p);for(const s of [-1,1]){const h=V.mix([s*10,42,91],[s*26,4,103],q);arm(p,s,h,[s,0,.2]);}const a=[0,58,101];station(p,a);const split=[0,24,99];cable(p,a,split,e.number===136?'band':'cable',false);for(const s of [-1,1])cable(p,split,p.j[s<0?'lh':'rh'],e.number===136?'band':'rope');return p;}
function curl(e,t){const n=e.number,q=rep(t),preacher=n===22,p=model(preacher?[0,0,35]:[0,0,61]);p.view=30;if(preacher){seat(p,0,28);plantedLegs(p,12,28);block(p,[0,20,59],[38,27,5],'pad',{right:[1,0,0],forward:V.unit([0,1,-.6]),up:V.unit([0,.6,1])});}else plantedLegs(p);
 for(const s of [-1,1]){const o=socket(p,s),upper=preacher?[0,.65,-.76]:[s*.05,0,-1],a=(8+120*q)*RAD;armFK(p,s,upper,[0,Math.sin(a),-Math.cos(a)]);}
 if(n===74)bandFeet(p);else if(n===194){const a=[0,51,6];station(p,a);pipe(p,[p.j.lh,p.j.rh],3,'grip');cable(p,a,V.mix(p.j.lh,p.j.rh,.5), 'cable',false);}else if(preacher){for(const s of [-1,1])dumbbell(p,p.j[s<0?'lh':'rh']);}else loads(p,e,{axis:n===21?[0,0,1]:[1,0,0]});p.grip=n===21?'neutral':'supinated';return p;}
function shrug(e,t){const q=rep(t),p=model();p.shoulder=V.add(p.shoulder,[0,0,6*q]);p.spine[p.spine.length-1]=p.shoulder;p.head=V.add(p.head,[0,0,1*q]);plantedLegs(p);hangArms(p);loads(p,e);p.view=18;return p;}
function squatPose(q,{front=false,smith=false,single=false,side=false}={}){const hip=[0,-14*q,61-30*q],a=(smith?0:24*q)*RAD,p=model(hip,[0,Math.sin(a),Math.cos(a)]);if(smith){p.shoulder=[0,0,hip[2]+Math.sqrt(36**2-(14*q)**2)];p.spine=[hip,V.mix(hip,p.shoulder,1/3),V.mix(hip,p.shoulder,2/3),p.shoulder];p.up=V.unit(V.sub(p.shoulder,hip));p.head=V.add(p.shoulder,V.add(V.mul(p.up,15),[0,1,0]));}p.view=side?60:36;if(single){leg(p,-1,[-6,0,4],[0,1,0],0,true);legFK(p,1,[0,1,-.12],[0,1,-.06],-.05);}else plantedLegs(p,15);return p;}
function squat(e,t){const n=e.number,q=rep(t),p=squatPose(q,{front:n===26,smith:n===144,single:n===143,side:n===143});
 if([25,26,144].includes(n)){const f=n===26?7:-4,c=V.add(p.shoulder,[0,f,-1]);for(const s of [-1,1])arm(p,s,V.add(c,[s*(n===26?28:25),0,0]),n===26?[0,1,0]:[s,0,-1]);bar(p,c);if(n===144)for(const s of [-1,1]){rail(p,s*43,-4,138);block(p,[s*43,-4,c[2]],[6,8,8],'machine');}}
 else {for(const s of [-1,1])arm(p,s,V.add(p.shoulder,[s*6,10,-8]),[s,0,-1]);if(n===27)kb(p,V.mix(p.j.lh,p.j.rh,.5));if(n===142)for(const s of [-1,1]){const h=V.add(p.shoulder,[s*15,7,0]);arm(p,s,h,[s,0,-1]);dumbbell(p,h,[0,1,0]);}if(n===78)bandFeet(p);}
 if([140,143].includes(n)){block(p,[0,-20,13],[43,30,26],'wood');}return p;}
function legPress(e,t){const n=e.number,q=rep(t),hack=n===29;if(hack){const p=model([0,-10-10*q,54-25*q],[0,-.12,.993]);p.view=65;for(const s of [-1,1]){leg(p,s,[s*13,18,7],[0,1,0]);arm(p,s,[s*24,-5,p.shoulder[2]-6],[s,0,-1]);rail(p,s*32,-20,130);}block(p,[0,-18,p.shoulder[2]-10],[37,7,48],'pad');block(p,[0,18,1],[52,40,5],'metal');for(const s of [-1,1])block(p,[s*19,-8,p.shoulder[2]+1],[10,18,9],'pad');return p;}
 const p=model([0,-26,29],[0,-.35,.937]);p.view=68;seat(p,-26,22);const pedal=[0,24-19*q,48-17*q];for(const s of [-1,1]){leg(p,s,V.add(pedal,[s*12,-6,0]),[0,0,1],-Math.PI/2);armFK(p,s,[s*.1,0,-1],[0,-.1,-1]);}block(p,pedal,[50,4,33],'metal');for(const s of [-1,1])pipe(p,[[s*30,-10,8],[s*30,65,82]],4);return p;
}
function lunge(e,t){const n=e.number,q=rep(t),walking=n===147,reverse=n===59,bulgarian=n===30,split=[30,145].includes(n),step=split?1:q,cycle=q,offset=0,hip=[0,-3,(split?57:61)-(split?25:29)*cycle],p=model(hip,[0,.08,.997]);p.view=65;
 if(walking){const travel=96*t,depth=Math.cos(2*Math.PI*t)**2;p.hip=[0,travel,61-29*depth];p.spine=[p.hip,V.add(p.hip,[0,1,12]),V.add(p.hip,[0,2,24]),V.add(p.hip,[0,3,36])];p.shoulder=p.spine.at(-1);p.head=V.add(p.shoulder,[0,1,15]);p.center=[0,travel,0];for(const s of [-1,1]){const u=(t+(s>0?.5:0))%1,stance=u<.5,phase=stance?u/.5:(u-.5)/.5,y=stance?mix(24,-24,phase):mix(-24,24,ease(phase)),z=4+(stance?0:8*Math.sin(Math.PI*phase));leg(p,s,[s*10,travel+y,z],[0,1,0],0,stance);armFK(p,s,[s*.08,0,-1],[s*.03,0,-1]);}loads(p,e);return p;}
 const frontY=split?20:reverse?0:24*step,backY=split?-31:reverse?-35*step:-10;
 leg(p,1,[10,frontY+offset,4],[0,1,0],0,true);leg(p,-1,[-10,backY+offset,bulgarian?30:8.2],[0,1,0],bulgarian?-.2:.55);if(bulgarian)block(p,[-10,backY,13],[34,27,26],'wood');
 if([31,59,147].includes(n)){hangArms(p);loads(p,e);}else hangArms(p);return p;
}
function stepUp(e,t){const n=e.number;if(n===166){const phase=2*Math.PI*t,p=model([0,0,60+Math.sin(phase*2)]);p.view=65;for(const s of [-1,1]){const f=phase+(s<0?Math.PI:0),end=[s*12,14+9*Math.cos(f),12+8*Math.sin(f)];leg(p,s,end,[0,1,0]);block(p,V.add(end,[0,3,-5]),[19,24,3],'metal');arm(p,s,[s*18,36,91],[0,-1,0]);}pipe(p,[[-23,36,3],[-23,36,96],[23,36,96],[23,36,3]],4);block(p,[0,9,1],[63,67,3],'machine');return p;}
 const rise=keyValue(t,[[0,0],[.18,0],[.55,1],[.68,1],[1,0]]),p=model([0,-6+16*rise,57+22*rise]);p.view=68;leg(p,1,[10,20,26],[0,1,0],0);leg(p,-1,[-10,-15+20*rise,4+22*rise],[0,1,0]);block(p,[0,20,11],[47,34,22],'wood');hangArms(p);return p;
}
function legExtension(e,t){const q=rep(t),p=model([0,0,38]);p.view=65;seat(p,0,31);for(const s of [-1,1]){const o=socket(p,s,false),k=V.add(o,[0,28,-5]);p.j[s<0?'lk':'rk']=k;const a=q*85*RAD,end=V.add(k,[0,29*Math.sin(a),-29*Math.cos(a)]);p.j[s<0?'la':'ra']=end;foot(p,s,end);arm(p,s,[s*18,0,35],[s,0,-1]);pipe(p,[[s*14,0,33],[s*18,0,35]],3,'grip');pipe(p,[[s*22,27,30],V.add(end,[0,2,4])],3);}const r=V.mix(p.j.la,p.j.ra,.5);block(p,V.add(r,[0,3,5]),[43,9,9],'pad');block(p,[28,15,30],[9,21,40],'machine');return p;}
function hinge(e,t){const n=e.number,dead=[34,96].includes(n),single=[148,149].includes(n),q=dead?1-rep(t):rep(t),a=(single?72:dead?58:65)*q*RAD,hip=[0,-(single?5:dead?18:18)*q,61-(dead?(n===96?16:24):single?0:3)*q],p=model(hip,[0,Math.sin(a),Math.cos(a)]);p.view=65;
 if(single){leg(p,-1,[-6,0,4],[0,1,0],0,true);const b=a+.18*(1-q),c=a+.65*(1-q);legFK(p,1,[0,-Math.sin(b),-Math.cos(b)],[0,-Math.sin(c),-Math.cos(c)],-.1);}else plantedLegs(p);
 if([38,77,150].includes(n)){if(n===38){const c=V.add(p.shoulder,[0,-4,0]);for(const s of [-1,1])arm(p,s,V.add(c,[s*24,0,0]),[s,0,-1]);bar(p,c);}else{hangArms(p);if(n===77){for(const s of [-1,1])cable(p,[s*11,0,0],V.add(p.shoulder,[s*11,-3,0]),'band',false);}}}
 else if([153,198].includes(n)){for(const s of [-1,1])armFK(p,s,[0,.05,-1],[0,.05,-1]);const h=V.mix(p.j.lh,p.j.rh,.5),a=[0,-63,7];station(p,a);cable(p,a,[0,-6,Math.max(8,h[2]-4)],n===153?'band':'cable',false);for(const s of [-1,1])cable(p,[0,-6,Math.max(8,h[2]-4)],p.j[s<0?'lh':'rh'],n===153?'band':'rope');}
 else{for(const s of [-1,1]){if(n===96)arm(p,s,[s*4,p.shoulder[1],p.shoulder[2]-46],[s,0,0]);else armFK(p,s,[0,0,-1],[0,0,-1]);}loads(p,e,{one:single});}return p;
}
function bridge(e,t){const n=e.number,q=rep(t),thrust=[36,152].includes(n),z=mix(thrust?14:6,thrust?34:25,q),shoulder=[0,thrust?30:31,thrust?35:6],hip=[0,shoulder[1]-Math.sqrt(36**2-(shoulder[2]-z)**2),z],p=model(hip,V.sub(shoulder,hip),[0,0,1]);p.shoulder=shoulder;p.spine=[hip,V.mix(hip,shoulder,1/3),V.mix(hip,shoulder,2/3),shoulder];p.head=V.add(shoulder,[0,16,3]);p.up=[0,1,0];p.view=65;p.scale=1.5;mat(p);if(thrust)bench(p,[0,27,28],[0,65,28]);
 for(const s of [-1,1]){if(n===65&&s>0)legFK(p,s,[0,-.3,.954],[0,-.3,.954],-.2);else leg(p,s,[s*11,-29,4],[0,0,1],0,true,[0,-1,0]);}
 if([36,151,152].includes(n)){const center=V.add(hip,[0,0,10]);for(const s of [-1,1])arm(p,s,V.add(center,[s*(n===36?17:7),0,0]),[s,0,1]);if(n===36)bar(p,center);else dumbbell(p,center,[1,0,0]);}else for(const s of [-1,1])groundArm(p,s,4);return p;
}
function hyperextension(e,t){const q=rep(t),a=(30+60*q)*RAD,p=model([0,0,55],[0,Math.sin(a),Math.cos(a)],[0,Math.cos(a),-Math.sin(a)]);p.view=65;for(const s of [-1,1])leg(p,s,[s*9,-27,8],[0,-1,0]);block(p,[0,4,48],[32,25,9],'pad');pipe(p,[[0,4,44],[0,-27,3]],6);block(p,[0,-27,14],[33,10,9],'pad');pipe(p,[[-23,-27,2],[23,-27,2]],5);for(const s of [-1,1])arm(p,s,V.add(p.shoulder,[s*4,8,-10]),[s,0,-1]);return p;}
function legCurl(e,t){const n=e.number,q=rep(t);if(n===64){const a=35*rep(t)*RAD,p=model([0,29*Math.sin(a),4+29*Math.cos(a)],[0,Math.sin(a),Math.cos(a)]);p.view=70;mat(p);for(const s of [-1,1]){const k=[s*6,0,4],end=[s*6,-29,4];p.j[s<0?'lk':'rk']=k;p.j[s<0?'la':'ra']=end;foot(p,s,end,0,[0,-1,0]);block(p,V.add(end,[0,0,5]),[12,12,9],'pad');p.contacts.push({kind:'knee',point:k,height:4});armFK(p,s,[s*.1,.7,-.7],[0,.85,-.5]);}pipe(p,[[-23,-29,2],[23,-29,2]],5);return p;}
 const p=model([0,0,39],[0,1,0],[0,0,-1]);p.view=68;bench(p,[0,-25,32],[0,60,32]);for(const s of [-1,1]){const k=V.add(socket(p,s,false),[0,-29,0]),a=q*105*RAD;p.j[s<0?'lk':'rk']=k;const end=V.add(k,[0,-29*Math.cos(a),29*Math.sin(a)]);p.j[s<0?'la':'ra']=end;foot(p,s,end,.1,[0,-1,0]);arm(p,s,[s*18,45,35],[s,0,-1]);}const r=V.mix(p.j.la,p.j.ra,.5);block(p,V.add(r,[0,0,-2]),[42,9,9],'pad');for(const s of [-1,1])pipe(p,[[s*22,-29,44],r],3);return p;
}
function plankBase(knees=false){return pushup({number:knees?123:5},0);}


function plank(e,t){const n=e.number,side=[42,161].includes(n);if(side){
 const bent=n===161,up=V.unit(bent?[0,.8660254,.5]:[0,.94,.341174]),right=V.cross([1,0,0],up),hip=[0,-6,bent?20.25:26.94],p=model(hip,up,[1,0,0],right);p.hipRight=right;p.view=bent?-130:-55;p.scale=1.5;mat(p);p.objects[0].size[0]=70;
 const support=socket(p,-1);p.j.le=[support[0],support[1],3];p.j.lh=V.add(p.j.le,[23,0,0]);p.contacts.push({kind:'elbow',point:p.j.le,height:3});arm(p,1,V.add(hip,[7,0,9]),[1,0,1]);
 const lowerHip=socket(p,-1,false),dz=lowerHip[2]-4,lowerKnee=[0,lowerHip[1]-Math.sqrt(29**2-dz**2),4],lowerAnkle=[0,lowerHip[1]-Math.sqrt(58**2-dz**2),4];
 for(const side of [-1,1]){const prefix=side<0?'l':'r',stack=V.mul(right,side<0?0:12);if(bent){const k=V.add(lowerKnee,stack),a=V.add(k,[-29,0,0]);p.j[prefix+'k']=k;p.j[prefix+'a']=a;foot(p,side,a,0,[0,-1,0]);if(side<0)p.contacts.push({kind:'knee',point:k,height:4});}
 else{const a=V.add(lowerAnkle,stack),o=socket(p,side,false);p.j[prefix+'k']=V.mix(o,a,.5);p.j[prefix+'a']=a;foot(p,side,a,0,[0,-1,0]);}}
 return p;}
 const p=plankBase(n===160);if(n===187){for(const s of [-1,1]){const local=s<0?t*2:(t-.5)*2,q=local>=0&&local<=1?rep(local):0,start=[s*18,25,3],end=V.add(p.shoulder,[-s*11,0,0]);arm(p,s,V.mix(start,end,q),[s*.25,-1,0]);}}return p;
}

function hangingRaise(e,t){const q=rep(t),span=23,handY=15,hipZ=144-Math.sqrt(46.9**2-(span-13)**2-handY**2)-36,p=model([0,0,hipZ]);p.view=60;p.scale=1.24;
 for(const side of [-1,1]){arm(p,side,[side*span,handY,144],[side,0,0]);rail(p,side*49,handY,150);if(e.number===43){const a=q*85*RAD;legFK(p,side,[0,Math.sin(a),-Math.cos(a)],[0,Math.sin(a),-Math.cos(a)],-.1);}else{const a=q*105*RAD;legFK(p,side,[0,Math.sin(a),-Math.cos(a)],[0,.1,-1],-.2);}}
 pipe(p,[[-49,handY,144],[49,handY,144]],4,'grip');return p;
}

function rollout(e,t){const q=rep(t),knee=[0,-27,4],hip=[0,-26+20*q,33-12*q],sh=V.add(hip,V.mul(V.unit([0,1,-.15-.18*q]),36)),p=model(hip,V.sub(sh,hip),[0,0,-1]);p.view=73;setSpine(p,[hip,V.mix(hip,sh,1/3),V.mix(hip,sh,2/3),sh]);mat(p);for(const s of [-1,1]){p.j[s<0?'lk':'rk']=V.add(knee,[s*7,0,0]);p.j[s<0?'la':'ra']=[s*7,-55,10];foot(p,s,p.j[s<0?'la':'ra'],.5,[0,-1,0]);arm(p,s,[s*8,30+38*q,9],[0,0,1]);}const h=V.mix(p.j.lh,p.j.rh,.5);shape(p,'wheel',{center:h,radius:9,axis:[1,0,0]});pipe(p,[p.j.lh,p.j.rh],3,'grip');return p;}
function crunch(e,t){const n=e.number,q=rep(t);if(n===45){const p=model([0,-15,33]);p.view=65;mat(p);const points=[p.hip];let a=p.hip;for(const ang of [15+15*q,20+30*q,20+55*q]){a=V.add(a,[0,12*Math.sin(ang*RAD),12*Math.cos(ang*RAD)]);points.push(a)}setSpine(p,points);p.forward=V.unit([0,p.up[2],-p.up[1]]);p.head=V.add(p.shoulder,V.mul(p.up,15));for(const s of [-1,1]){legFK(p,s,[0,0,-1],[0,-1,0],0,[0,-1,0]);arm(p,s,V.add(p.head,[s*9,2,-2]),[s,1,0]);}const a0=[0,58,145];station(p,a0);cable(p,a0,V.mix(p.j.lh,p.j.rh,.5));return p;}
 const p=supine();mat(p);const heel=n===185;articulatedCrunch(p,heel?.7:n===157?.65*q:q);bentSupineLegs(p,12,heel?-13:-29);if(heel){const shift=7*wave(t);p.spine=p.spine.map((x,i)=>V.add(x,[shift*i/3,0,0]));p.shoulder=p.spine.at(-1);p.head=V.add(p.head,[shift,0,0]);for(const s of [-1,1])arm(p,s,[s*12,-8,5],[s,0,1]);}else for(const s of [-1,1]){if(n===157)arm(p,s,[s*10,p.shoulder[1]-43,p.shoulder[2]+2],[0,0,1]);else arm(p,s,V.add(p.shoulder,[-s*6,0,8]),[s,-1,1]);}return p;
}
function twist(e,t){const n=e.number,a=wave(t)*40*RAD;if(n===46){const axis=V.unit([0,.5,.866]),rotate=v=>V.add(V.add(V.mul(v,Math.cos(a)),V.mul(V.cross(axis,v),Math.sin(a))),V.mul(axis,V.dot(axis,v)*(1-Math.cos(a)))),p=model([0,0,9],axis,rotate([0,-.866,.5]),rotate([1,0,0]));p.view=125;p.scale=1.4;mat(p);bentSupineLegs(p,12,-29);for(const s of [-1,1])arm(p,s,V.add(p.shoulder,V.add(V.mul(p.forward,28),V.mul(p.right,s*5))),[s,0,-1]);return p;}
 const p=model();p.right=rotZ([1,0,0],a);p.forward=rotZ([0,1,0],a);p.view=30;plantedLegs(p,17);const h=[16*wave(t),20,85-15*wave(t)];for(const s of [-1,1])arm(p,s,V.add(h,[s*4,0,0]),[s,0,-.6]);const origin=[-65,12,133];station(p,origin);cable(p,origin,V.mix(p.j.lh,p.j.rh,.5));return p;
}
function horizontalPress(e,t){const n=e.number,q=rep(t),machine=n===127,p=model(machine?[0,0,35]:[0,0,61]);p.view=n===47?28:60;if(machine){seat(p,0,28);plantedLegs(p,12,27);}else plantedLegs(p,14);
 for(const s of [-1,1]){const a=(-86+30*q)*RAD,pivot=[s*22,10,124],h=machine?V.add(pivot,[0,59*Math.cos(a),59*Math.sin(a)]):[s*(n===47?4:16),12+30*q,p.shoulder[2]-5];arm(p,s,h,[s,0,-1]);if(machine){pipe(p,[[s*34,-12,124],pivot,h],4);shape(p,'handle',{center:h});rail(p,s*34,-12,132);}}
 if(n===47){const a=[-64,19,89];station(p,a);cable(p,a,V.mix(p.j.lh,p.j.rh,.5));}if(n===69)for(const s of [-1,1])cable(p,[s*16,-49,89],p.j[s<0?'lh':'rh'],'band');return p;
}
function calfRaise(e,t){const n=e.number,q=rep(t),single=[154,155].includes(n),seated=n===49,pitch=.47*q,toeY=9,ankle=[0,toeY-9*Math.cos(pitch)+4*Math.sin(pitch),9*Math.sin(pitch)+4*Math.cos(pitch)],rise=ankle[2]-4,p=model([0,0,seated?35:61+rise]);p.view=65;
 if(seated)seat(p,0,28);for(const s of [-1,1]){if(single&&s<0){legFK(p,s,[0,-.1,-1],[0,-.8,.6],.3);continue;}const end=[s*11,seated?28+ankle[1]:ankle[1],ankle[2]];leg(p,s,end,[0,1,0],pitch,true);}
 if(seated){for(const s of [-1,1])arm(p,s,[s*12,21,43],[s,0,-1]);block(p,[0,24,43+rise],[35,12,8],'pad');pipe(p,[[25,24,3],[25,24,48+rise],[0,24,48+rise]],3);}else{hangArms(p);if(n===48){for(const s of [-1,1]){rail(p,s*27,-12,120);block(p,[s*14,0,p.shoulder[2]+2],[11,15,7],'pad');arm(p,s,[s*22,5,p.shoulder[2]-18],[s,0,-1]);pipe(p,[[s*27,-12,p.shoulder[2]-18],p.j[s<0?'lh':'rh']],3,'grip');}}if(n===155)dumbbell(p,p.j.rh);}return p;
}
function gait(e,t){const n=e.number,running=[51,88,89].includes(n),march=[89,168].includes(n),carry=[91,92].includes(n),a=2*Math.PI*t,stride=march?15:n===88?26:running?22:20,p=model([0,0,(running&&!march?(n===88?52:54):57)+(running?3*Math.cos(2*a):1.4*Math.cos(2*a))],[0,n===88?.25:running?.12:.03,1]);p.view=65;
 for(const s of [-1,1]){const u=(t+(s>0?.5:0))%1,duty=running?.4:.6,stance=u<duty,phase=stance?u/duty:(u-duty)/(1-duty),y=stance?mix(stride,-stride,phase):mix(-stride,stride,ease(phase)),z=4+(stance?0:(march?29:running?17:10)*Math.sin(Math.PI*phase));leg(p,s,[s*8,y,z],[0,1,0],stance?0:.2*Math.sin(Math.PI*phase),stance);
  if(carry)armFK(p,s,[s*.08,0,-1],[s*.02,0,-1]);else{const ang=Math.sin(a+(s>0?Math.PI:0))*(running?.65:.38);armFK(p,s,[0,Math.sin(ang),-Math.cos(ang)],running||march?[0,1,-.25]:[0,Math.sin(ang+.2),-Math.cos(ang+.2)]);}}
 if([50,51].includes(n)){block(p,[0,0,-3],[48,100,5],'machine');pipe(p,[[-25,41,0],[-25,41,100],[25,41,100],[25,41,0]],4);block(p,[0,41,99],[43,8,14],'console');for(let y=-36;y<40;y+=16)pipe(p,[[-20,y,0],[20,y,0]],.8,'mat');}
 if(carry)loads(p,e,{one:n===92});return p;
}
function mountain(e,t){const p=plankBase();p.feet=[];for(const s of [-1,1]){const u=(t+(s>0?.5:0))%1,q=rep(u);const end=V.mix([s*6,-62.71,9.82],[s*13,3,14],q);leg(p,s,end,[s*.2,-1,-.2],mix(1.08,.4,q));}return p;}
function burpee(e,t){const stand=squatPose(keyValue(t,[[0,0],[.14,1],[.25,1],[.75,1],[.87,0],[1,0]])),pl=plankBase(),k=keyValue(t,[[0,0],[.22,0],[.38,1],[.62,1],[.78,0],[1,0]]),down=keyValue(t,[[0,0],[.38,0],[.5,1],[.62,0],[1,0]]);
 const hip=V.mix(stand.hip,V.add(pl.hip,[0,0,-14*down]),k),sh=V.mix(stand.shoulder,V.add(pl.shoulder,[0,0,-23*down]),k),p=model(hip,V.sub(sh,hip),V.mix([0,1,0],[0,0,-1],k));setSpine(p,[hip,V.mix(hip,sh,1/3),V.mix(hip,sh,2/3),sh]);p.view=70;mat(p);const jump=keyValue(t,[[0,0],[.84,0],[.92,12],[1,0]]);p.hip=V.add(p.hip,[0,0,jump]);p.spine=p.spine.map(v=>V.add(v,[0,0,jump]));p.shoulder=p.spine.at(-1);p.head=V.add(p.head,[0,0,jump]);
 for(const s of [-1,1]){const f=V.mix([s*13,0,4+jump],[s*6,-62.71,9.82],k);leg(p,s,f,[0,1,-.1]);let h=V.mix(V.add(p.shoulder,[s*17,0,-42]),[s*18,25,3],k);const o=socket(p,s),d=V.len(V.sub(h,o));if(d>46.8)h=V.add(o,V.mul(V.unit(V.sub(h,o)),46.8));arm(p,s,h,[s*.2,-1,0]);}return p;
}
function swing(e,t){const q=rep(t),a=65*(1-q)*RAD,p=model([0,-15*(1-q),54+3*q],[0,Math.sin(a),Math.cos(a)]);p.view=68;plantedLegs(p);const angle=(-8+95*q)*RAD;for(const s of [-1,1])arm(p,s,[s*4,p.shoulder[1]+46*Math.sin(angle),p.shoulder[2]-46*Math.cos(angle)],[s,0,0]);kb(p,V.mix(p.j.lh,p.j.rh,.5));return p;}
function olympic(e,t){const n=e.number;if(n===56){const q=rep(t),p=squatPose(1-q),press=ease((q-.5)/.5),height=-3+(3+Math.sqrt(46.9**2-6**2-3**2))*press,c=V.add(p.shoulder,[0,15,height]);c[1]=p.shoulder[1]+mix(15,3,ease((c[2]-p.head[2]-11)/8));p.view=38;for(const s of [-1,1])arm(p,s,V.add(c,[s*19,0,0]),[s,.5,-.3]);bar(p,c);return p;}
 const sn=n===55,h=keyValue(t,[[0,[0,-18,37]],[.2,[0,-9,49]],[.31,[0,0,60]],[.43,[0,-8,43]],[.57,[0,0,57]],[.73,[0,-4,53]],[.93,[0,-18,37]],[1,[0,-18,37]]]),a=keyValue(t,[[0,58],[.2,25],[.31,0],[.43,8],[.57,0],[.73,20],[.93,58],[1,58]])*RAD,p=model(h,[0,Math.sin(a),Math.cos(a)]);p.view=50;p.scale=1.32;plantedLegs(p);const rel=keyValue(t,[[0,sn?-42:-45],[.2,-40],[.31,-32],[.43,sn?41:-4],[.57,sn?41:-4],[.73,-25],[.93,sn?-42:-45],[1,sn?-42:-45]]),barY=keyValue(t,[[0,9],[.2,9],[.31,6],[.43,sn?0:10],[.57,sn?0:10],[.73,9],[1,9]]),c=[0,barY,p.shoulder[2]+rel];if(sn){const weight=1-ease((Math.abs(c[2]-p.head[2])-11)/8),front=p.head[1]+Math.abs(p.up[1])*9+Math.abs(p.forward[1])*7+1.5;c[1]=mix(c[1],Math.max(c[1],front),weight);}for(const s of [-1,1])arm(p,s,V.add(c,[s*(sn?32:20),0,0]),sn?[0,-1,0]:[s,.3,-.2]);bar(p,c,[1,0,0],sn?48:43);return p;
}
function getup(e,t){const u=t<=.6?t/.6:(1-t)/.4,h=keyValue(u,[[0,[0,0,6]],[.18,[0,0,6]],[.36,[0,0,16]],[.5,[0,0,24]],[.65,[0,-2,33]],[.8,[0,-2,38]],[1,[0,0,61]]]),sh=keyValue(u,[[0,[0,36,6]],[.18,[0,29,30]],[.36,[0,30,39]],[.5,[0,28,46]],[.65,[0,14,65]],[.8,[0,3,74]],[1,[0,0,97]]]),up=V.unit(V.sub(sh,h)),p=model(h,up,[0,-up[2],up[1]]);p.view=120;p.scale=1.27;mat(p);
 const lf=keyValue(u,[[0,[-8,-57.5,4]],[.36,[-12,-44,4]],[.5,[-14,-26,8]],[.65,[-10,34,4]],[.8,[-10,32,4]],[1,[-11,0,4]]]),rf=keyValue(u,[[0,[10,-29,4]],[.36,[14,-20,4]],[.5,[14,-10,4]],[.65,[12,-24,4]],[.8,[12,-24,4]],[1,[11,0,4]]]);for(const [s,end] of [[-1,lf],[1,rf]])leg(p,s,end,[s*.35,-u,1-u],0,false,u<.5?[0,-1,0]:[0,1,0]);
 const hand=keyValue(u,[[0,[-24,7,3]],[.18,[-30,17,3]],[.36,[-29,19,3]],[.5,[-28,21,3]],[.65,[-25,21,25]],[.8,[-18,12,44]],[1,[-17,0,50.3]]]);arm(p,-1,hand,[-1,-.2,0]);armFK(p,1,[0,0,1],[0,0,1]);kb(p,p.j.rh);return p;
}
function invertedRow(e,t){const q=rep(t),ankle=[0,-55,4],hip=[0,-6,24+7*q],sh=[0,27,38+15*q],p=model(hip,V.sub(sh,hip),[0,0,1]);setSpine(p,[hip,V.mix(hip,sh,1/3),V.mix(hip,sh,2/3),sh]);p.view=65;for(const s of [-1,1]){leg(p,s,V.add(ankle,[s*9,0,0]),[0,0,1],0,true,[0,-1,0]);arm(p,s,[s*19,31,75],[s,-.2,-1]);rail(p,s*42,31,78);}pipe(p,[[-42,31,75],[42,31,75]],4,'grip');return p;}
function hollow(e,t){const p=supine(6),a=(e.number===186?10*wave(t):0)*RAD,rotate=v=>[v[0],v[1]*Math.cos(a)-v[2]*Math.sin(a),v[1]*Math.sin(a)+v[2]*Math.cos(a)];p.up=rotate([0,.96,.28]);p.forward=rotate([0,-.28,.96]);p.spine=[p.hip,V.add(p.hip,V.mul(p.up,12)),V.add(p.hip,V.mul(p.up,24)),V.add(p.hip,V.mul(p.up,36))];p.shoulder=p.spine.at(-1);p.head=V.add(p.shoulder,V.mul(p.up,15));for(const s of [-1,1]){legFK(p,s,rotate([0,-.97,.243]),rotate([0,-.97,.243]),-.1,[0,-1,0]);armFK(p,s,rotate([0,.97,.243]),rotate([0,.97,.243]));}mat(p);p.view=70;return p;}
function quadrupedBase(){const p=model([0,-10,33],[0,.94,.342],[0,.342,-.94]);p.view=68;mat(p);for(const s of [-1,1]){legFK(p,s,[0,0,-1],[0,-1,0],0,[0,-1,0]);arm(p,s,[s*13,31,3],[s*.35,0,-1]);}return p;}
function quadruped(e,t){const n=e.number,q=rep(t);if(n===195){const p=model([0,0,57],[0,.25,.968]);p.view=67;leg(p,-1,[-7,0,4],[0,1,0],0,true);const a=.12+.6*q,b=.65+.07*q;legFK(p,1,[0,-Math.sin(a),-Math.cos(a)],[0,-Math.sin(b),-Math.cos(b)],.1);for(const s of [-1,1])arm(p,s,[s*18,38,84],[0,-1,0]);pipe(p,[[-23,40,0],[-23,40,89],[23,40,89],[23,40,0]],4);const a0=[20,62,6];station(p,a0);cable(p,a0,p.j.ra,'cable',false);shape(p,'cuff',{center:p.j.ra});return p;}
 const p=quadrupedBase();if(n===66){const u=t<.5?t*2:(t-.5)*2,a=rep(u),s=t<.5?1:-1;const end=V.mix([s*13,31,3],[s*13,69,48],a);arm(p,s,end,[s*.35,0,-1]);legFK(p,-s,V.mix([0,0,-1],[0,-1,.15],a),V.mix([0,-1,0],[0,-1,.15],a),mix(0,.1,a),[0,-1,0]);}
 if(n===199){const a=q*90*RAD;legFK(p,1,[0,-Math.sin(a),-Math.cos(a)],[0,-Math.cos(a),Math.sin(a)],q*.1,[0,-1,0]);}
 if(n===103){const bend=wave(t),hip=p.hip,sh=p.shoulder;const points=[hip,V.add(V.mix(hip,sh,1/3),[0,0,6*bend]),V.add(V.mix(hip,sh,2/3),[0,0,7*bend]),sh];setSpine(p,points);p.head=V.add(sh,V.mul(V.unit([0,1,.3*bend]),15));p.headUp=V.unit([0,1,.6*bend]);}
 if(n===113){const p=model([0,-10,33],[0,.894,-.447],[.661,-.335,-.671],[.75,.296,.592]);p.view=-55;mat(p);for(const s of [-1,1])legFK(p,s,[0,0,-1],[0,-1,0],0,[0,-1,0]);arm(p,-1,[25,24,4],[0,1,0]);arm(p,1,[12,60,3],[1,0,1]);p.head=[6,34,12];p.headUp=[0,1,0];p.headRight=[.7,0,.714];return p;}return p;
}
function superman(e,t){const q=rep(t),p=model([0,0,6],[0,.99,.12+q*.15],[0,0,-1]);p.view=70;mat(p);for(const s of [-1,1]){armFK(p,s,[0,.98,.05+.2*q],[0,.98,.05+.2*q]);legFK(p,s,[0,-1,.02+.16*q],[0,-1,.02+.16*q],0,[0,-1,0]);}return p;}
function pullApart(e,t){const q=rep(t),p=model();p.view=20;plantedLegs(p);for(const s of [-1,1]){const a=(12+70*q)*RAD;armFK(p,s,[s*Math.sin(a),Math.cos(a),-.05],[s*Math.sin(a),Math.cos(a),-.05]);}cable(p,p.j.lh,p.j.rh,'band',false);return p;}
function pullover(e,t){const n=e.number,q=rep(t);if(n===83){const p=supine(39);bench(p);bentSupineLegs(p);for(const s of [-1,1]){const a=q*100*RAD;arm(p,s,[s*4,p.shoulder[1]+46*Math.sin(a),p.shoulder[2]+46*Math.cos(a)],[s,0,0]);}dumbbell(p,V.mix(p.j.lh,p.j.rh,.5),[1,0,0]);return p;}
 const p=model([0,-4,57],[0,.12,.993]);p.view=65;plantedLegs(p);const a=(105-98*q)*RAD;for(const s of [-1,1])armFK(p,s,[0,Math.sin(a),-Math.cos(a)],[0,Math.sin(a),-Math.cos(a)]);pipe(p,[p.j.lh,p.j.rh],3,'grip');const a0=[0,61,145];station(p,a0);cable(p,a0,V.mix(p.j.lh,p.j.rh,.5),'cable',false);return p;
}
function jump(e,t){const n=e.number,jack=n===169,rope=n===87,bound=n===86,broad=n===85,boxJump=n===84;if(jack){const q=rep(t),p=model([0,0,61+.2*q]);p.view=5;for(const s of [-1,1]){leg(p,s,[s*(7+22*q),0,4+4*q],[0,1,0]);const a=(5+162*q)*RAD;armFK(p,s,[s*Math.sin(a),0,-Math.cos(a)],[s*Math.sin(a),0,-Math.cos(a)]);}return p;}
 if(rope){const q=rep(t+.5),p=model([0,0,57+7*q]);p.view=30;for(const s of [-1,1]){leg(p,s,[s*9,0,4+7*q],[0,1,0]);arm(p,s,[s*24,5,57+2*q],[s,0,-1]);}const a=2*Math.PI*t,pts=[];for(let k=0;k<=24;k++){const u=k/24*Math.PI,xc=-24+48*k/24,r=Math.sin(u)*66;pts.push([xc,5+r*Math.sin(a),Math.max(1,57+2*q-r*Math.cos(a))])}pipe(p,pts,1.3,'rope');for(const s of [-1,1])pipe(p,[p.j[s<0?'lh':'rh'],V.add(p.j[s<0?'lh':'rh'],[0,3,-5])],3,'grip');return p;}
 if((boxJump||broad)&&t>=.62){const first=clamp((t-.62)/.165),second=clamp((t-.785)/.165),back=boxJump?-24:-16,front=boxJump?8:26,left=mix(front,back,ease(first)),right=mix(front,back,ease(second)),extent=Math.abs(left-right)/(front-back),reload=.55*ease((t-.95)/.05),height=boxJump?25*(1-ease((first-.45)/.55)):0,load=.15*extent+reload,hip=[0,(left+right)/2-14*load,61+height-30*load],a=24*load*RAD,p=model(hip,[0,Math.sin(a),Math.cos(a)]);p.view=65;
  for(const s of [-1,1]){const u=s<0?first:second,y=s<0?left:right,z=boxJump?29+10*Math.sin(Math.PI*u)-25*ease((u-.72)/.28):4+8*Math.sin(Math.PI*u);leg(p,s,[s*12,y,z],[0,1,0]);const aa=-.3*ease((t-.95)/.05);armFK(p,s,[s*.1,Math.sin(aa),-Math.cos(aa)],[s*.1,Math.sin(aa+.3),-Math.cos(aa+.3)]);}if(boxJump)block(p,[0,8,12.5],[47,32,25],'wood');return p;}
 const load=keyValue(t,[[0,.55],[.18,1],[.22,0],[.43,0],[.53,.7],[.62,0],[.84,0],[.93,.7],[1,.55]]),
 lift=boxJump?keyValue(t,[[0,0],[.22,0],[.33,43],[.43,25],[.62,25],[.72,46],[.84,0],[1,0]]):keyValue(t,[[0,0],[.22,0],[.32,24],[.43,0],[.62,0],[.73,24],[.84,0],[1,0]]),
 distance=bound?34:broad?42:boxJump?32:0,travel=keyValue(t,[[0,0],[.22,0],[.43,distance],[.62,distance],[.84,0],[1,0]]),
 p=squatPose(load),offset=bound?[travel-distance/2,0,lift]:[0,travel-(boxJump?24:16),lift];p.view=bound?10:65;p.hip=V.add(p.hip,offset);p.spine=p.spine.map(v=>V.add(v,offset));p.shoulder=p.spine.at(-1);p.head=V.add(p.head,offset);p.feet=[];
 const swap=keyValue(t,[[0,0],[.22,0],[.43,1],[.62,1],[.84,0],[1,0]]);
 for(const s of [-1,1]){const extra=bound?12*(s<0?1-swap:swap):0,end=bound?[s*8+offset[0],0,4+lift+extra]:[s*12,offset[1],4+lift];leg(p,s,end,[0,1,0]);const a=keyValue(t,boxJump||broad?[[0,-.3],[.18,-.7],[.32,1.7],[.43,.7],[.53,.1],[.62,0],[1,0]]:[[0,-.3],[.18,-.7],[.32,1.7],[.43,.7],[.53,-.7],[.73,1.7],[.84,.7],[1,-.3]]),aa=bound?s*a:a;armFK(p,s,[s*.1,Math.sin(aa),-Math.cos(aa)],[s*.1,Math.sin(aa+.3),-Math.cos(aa+.3)]);}
 if(boxJump)p.scale=1.3;if(boxJump)block(p,[0,8,12.5],[47,32,25],'wood');return p;
}

function slam(e,t){const q=keyValue(t,[[0,0],[.25,0],[.45,1],[.58,1],[.75,.7],[1,0]]),p=squatPose(q*.8);p.view=58;const a=(150-145*q)*RAD;for(const s of [-1,1])armFK(p,s,[0,Math.sin(a),-Math.cos(a)],[0,Math.sin(a),-Math.cos(a)]);const held=V.mix(p.j.lh,p.j.rh,.5),ball=t>=.33&&t<.66?keyValue(t,[[.33,held],[.49,[0,30,8]],[.57,[0,30,8]],[.66,held]]):held;shape(p,'ball',{center:ball,radius:8});return p;}
function coreLegs(e,t){const n=e.number,p=supine(6),q=rep(t),l=t<.5?rep(t*2):0,r=t>=.5?rep((t-.5)*2):0;mat(p);p.view=[183,181].includes(n)?40:68;
 if([178,179].includes(n)){const a=(8+57*q)*RAD;setSpine(p,[p.hip,V.add(p.hip,[0,12*Math.cos(a),12*Math.sin(a)]),V.add(p.hip,[0,24*Math.cos(a),24*Math.sin(a)]),V.add(p.hip,[0,36*Math.cos(a),36*Math.sin(a)])]);p.forward=[0,-Math.sin(a),Math.cos(a)];p.head=V.add(p.shoulder,V.mul(p.up,15));for(const s of [-1,1]){const b=(8+62*q)*RAD;legFK(p,s,[0,-Math.cos(b),Math.sin(b)],[0,-Math.cos(b),Math.sin(b)],-.1,[0,-1,0]);const aa=(4+144*q)*RAD;arm(p,s,[s*(n===179?4:6),p.shoulder[1]+46*Math.cos(aa),p.shoulder[2]+46*Math.sin(aa)],[s,0,0]);}if(n===179)dumbbell(p,V.mix(p.j.lh,p.j.rh,.5),[1,0,0]);return p;}
 if(n===182){p.hip=V.add(p.hip,[0,-3*q,10*q]);p.spine=[p.hip,[0,12,13+5*q],[0,24,10],[0,36,10]];p.shoulder=p.spine.at(-1);p.head=[0,51,11];}
 if(n===183){articulatedCrunch(p,.8);const a=28*wave(t)*RAD;p.right=[Math.cos(a),0,Math.sin(a)];p.forward=[-Math.sin(a),0,Math.cos(a)];}
 if(n===180)articulatedCrunch(p,.5);
 for(const s of [-1,1]){
  const active=s<0?l:r;
  if(n===158){const a=(7+80*q)*RAD;legFK(p,s,[0,-Math.cos(a),Math.sin(a)],[0,-Math.cos(a),Math.sin(a)],-.1,[0,-1,0]);}
  else if(n===184){const a=(12+8*wave(t+(s<0?.5:0)))*RAD;legFK(p,s,[0,-Math.cos(a),Math.sin(a)],[0,-Math.cos(a),Math.sin(a)],-.2,[0,-1,0]);}
  else if(n===181)leg(p,s,[s*9,-28,38-34*active],[0,0,1],0,false,[0,-1,0]);
  else if(n===182){const a=(72+13*q)*RAD;legFK(p,s,[0,-Math.cos(a),Math.sin(a)],[0,-1,0],-.1,[0,-1,0]);}
  else {const extension=n===93?active:1-active,a=(90-75*extension)*RAD,b=(15*extension)*RAD;legFK(p,s,[0,-Math.cos(a),Math.sin(a)],[0,-Math.cos(b),Math.sin(b)],-.1,[0,-1,0]);}
  if(n===93){const x=s<0?r:l,a=x*Math.PI/2;armFK(p,s,[0,Math.sin(a),Math.cos(a)],[0,Math.sin(a),Math.cos(a)]);}
  else if(n===183)arm(p,s,V.add(p.head,V.add(V.mul(p.right,s*10),[0,-2,2])),[s,0,1]);
  else if(n===181)armFK(p,s,[0,0,1],[0,0,1]);else groundArm(p,s,0);
 }return p;
}
function bandWalk(e,t){const lead=ease(t/.42),follow=ease((t-.42)/.42),travel=12*lead+12*follow,p=model([travel,0,49]);p.view=10;p.center=[travel,0,0];for(const s of [-1,1]){const u=clamp(s>0?t/.42:(t-.42)/.42),x=s>0?14+24*lead:-14+24*follow,z=4+5*Math.sin(Math.PI*u);leg(p,s,[x,0,z],[0,1,0]);arm(p,s,V.add(p.shoulder,[s*5,10,-12]),[s,0,-1]);}const l=V.mix(p.j.lk,p.j.la,.25),r=V.mix(p.j.rk,p.j.ra,.25);pipe(p,[V.add(l,[0,3,0]),V.add(r,[0,3,0])],4,'band');pipe(p,[V.add(l,[0,-3,0]),V.add(r,[0,-3,0])],3,'band');return p;}
function clamshell(e,t){const q=rep(t),p=model([0,0,15],[0,1,0],[1,0,0],[0,0,1]);p.hipRight=[0,0,1];p.view=-55;p.scale=1.5;mat(p);p.head=[0,51,15];p.j.le=[0,43,3];p.j.lh=[0,58,3];arm(p,1,[10,3,21],[1,0,1]);leg(p,-1,[0,-44,4],[1,0,0],0,false,[0,-1,0]);const theta=70*q*RAD;leg(p,1,[0,-44,10],[Math.cos(theta),-.24*Math.sin(theta),Math.sin(theta)],0,false,[0,-1,0]);return p;}
function tricepsExtension(e,t){const q=rep(t),p=model();p.view=60;plantedLegs(p);for(const s of [-1,1]){const a=(5+108*q)*RAD;armFK(p,s,[s*.12,0,1],[0,-Math.sin(a),Math.cos(a)]);}if(e.number===119){const a=(5+108*q)*RAD;for(const s of [-1,1])arm(p,s,[s*4,p.shoulder[1]-22*Math.sin(a),p.shoulder[2]+24+22*Math.cos(a)],[s,0,0]);dumbbell(p,V.mix(p.j.lh,p.j.rh,.5),[1,0,0]);}else{const a=[0,-55,90];station(p,a);const h=V.mix(p.j.lh,p.j.rh,.5),fork=V.add(h,[0,-6,4]);cable(p,a,fork,e.number===122?'band':'cable',false);for(const s of [-1,1])cable(p,fork,p.j[s<0?'lh':'rh'],e.number===122?'band':'rope');}return p;}
function kickback(e,t){const q=rep(t),p=model([0,-12,54],[0,.91,.414]);p.view=67;plantedLegs(p);for(const s of [-1,1]){const o=socket(p,s),j=V.add(o,[0,-24,0]);p.j[s<0?'le':'re']=j;const a=q*Math.PI/2;p.j[s<0?'lh':'rh']=V.add(j,[0,-23*Math.sin(a),-23*Math.cos(a)]);}loads(p,e);return p;}
function externalRotation(e,t){const q=rep(t),p=model();p.view=14;plantedLegs(p,11);for(const s of [-1,1]){const o=socket(p,s),el=V.add(o,[0,0,-24]);p.j[s<0?'le':'re']=el;const a=(5+65*q)*RAD;p.j[s<0?'lh':'rh']=V.add(el,[s*23*Math.sin(a),23*Math.cos(a),0]);}cable(p,p.j.lh,p.j.rh,'band',false);return p;}
function sideLunge(e,t){const q=rep(t),p=model([18*q,0,57-13*q],[0,.12,.993]);p.view=15;for(const s of [-1,1]){leg(p,s,[s*30,0,4],[0,1,0],0,true);arm(p,s,V.add(p.shoulder,[s*5,10,-10]),[s,0,-1]);}return p;}

function stationaryBike(e,t){
 const a=t*Math.PI*2,p=model([0,-17,55],[0,.45,.893]);p.view=64;
 // Saddle, seatpost, frame, enclosed flywheel and two stationary stabilizers.
 block(p,[0,-17,49],[17,22,4],'pad');pipe(p,[[0,-20,8],[0,-17,47]],4);pipe(p,[[0,-20,8],[0,18,20],[0,30,52],[0,-17,46],[0,18,20]],5);pipe(p,[[0,30,20],[0,35,80]],4);pipe(p,[[-23,35,80],[23,35,80]],4,'grip');
 for(const y of [-40,40]){pipe(p,[[-29,y,3],[29,y,3]],6,'grip');pipe(p,[[0,y,3],[0,y<0?-20:30,12]],4);}
 shape(p,'cylinder',{center:[0,18,20],axis:[1,0,0],length:9,radius:17,color:'machine'});ringBike(p);
 for(const side of [-1,1]){const phase=a+(side>0?Math.PI:0),pedal=[side*13,18+12*Math.cos(phase),20+12*Math.sin(phase)],end=V.add(pedal,[0,-2,4]);leg(p,side,end,[0,1,0]);pipe(p,[[side*7,18,20],pedal],2.5,'grip');block(p,pedal,[12,10,2],'grip');arm(p,side,[side*21,35,80],[side,0,-1]);}
 return p;
}
function ringBike(p){shape(p,'wheel',{center:[5.5,18,20],axis:[1,0,0],radius:13});}
function cardio(e,t){const n=e.number,a=t*Math.PI*2;if(n===162)return stationaryBike(e,t);if(n===165){const drive=keyValue(t,[[0,0],[.35,1],[.43,1],[1,0]]),body=ease((drive-.45)/.5),pull=ease((drive-.75)/.25),p=model([0,-8-19*drive,31],[0,.28-.47*body,1]);p.view=69;seat(p,p.hip[1],24,false,25);pipe(p,[[0,-59,13],[0,52,13]],6);block(p,[0,60,28],[40,28,53],'machine');for(const s of [-1,1]){leg(p,s,[s*11,23.5,10],[0,0,1],-Math.PI/2);arm(p,s,V.mix(V.add(p.shoulder,[s*9,44,-7]),[s*9,p.shoulder[1]+8,p.shoulder[2]-12],pull),[0,-1,0]);}pipe(p,[p.j.lh,p.j.rh],3,'grip');cable(p,[0,56,47],V.mix(p.j.lh,p.j.rh,.5),'cable',false);block(p,[0,31,10],[36,7,23],'metal');return p;}
 if(n===164){const p=model([0,0,60+2*Math.cos(a*2)]);p.view=63;block(p,[0,8,-1],[60,90,4],'machine');for(const s of [-1,1]){const aa=a+(s>0?Math.PI:0),end=[s*13,22*Math.cos(aa),10+5*Math.sin(aa)];leg(p,s,end,[0,1,0]);block(p,V.add(end,[0,2,-5]),[18,27,3],'metal');const handle=[s*24,25-14*Math.cos(aa),88];arm(p,s,handle,[s,0,-1]);pipe(p,[[s*24,24,8],handle,[s*24,handle[1],112]],3);}block(p,[0,32,24],[35,25,42],'machine');return p;}
 const rec=n===163,hip=rec?[0,-26,29]:[0,-16,52],p=model(hip,rec?[0,-.32,.948]:[0,.23,.973]);p.view=68;seat(p,hip[1],hip[2]-7,rec);const crank=rec?[0,18,23]:[0,10,19],radius=13;for(const s of [-1,1]){const aa=a+(s>0?Math.PI:0),pedal=V.add(crank,[s*11,radius*Math.cos(aa),radius*Math.sin(aa)]),end=V.add(pedal,[0,-2,4]);leg(p,s,end,[0,0,1]);pipe(p,[crank,pedal],2);block(p,pedal,[12,11,2],'metal');arm(p,s,rec?[s*18,-23,35]:[s*21,27,83],[s,0,-1]);}shape(p,'wheel',{center:crank,radius:15,axis:[1,0,0]});pipe(p,[[0,-41,2],hip,crank,[0,39,2]],5);pipe(p,[[-25,-41,2],[25,-41,2]],4);pipe(p,[[-25,39,2],[25,39,2]],4);if(!rec)pipe(p,[[-23,27,83],[23,27,83],[0,27,12]],4);return p;
}
function wrist(e,t){const p=model();p.view=48;plantedLegs(p);for(const s of [-1,1]){armFK(p,s,[s*.05,.9,-.436],[0,1,0]);const h=p.j[s<0?'lh':'rh'];shape(p,'hand',{center:h,direction:[0,Math.cos(2*Math.PI*t),Math.sin(2*Math.PI*t)]});p.j[s<0?'lfingertip':'rfingertip']=V.add(h,[0,6*Math.cos(2*Math.PI*t),6*Math.sin(2*Math.PI*t)]);}return p;}
function foamRoll(e,t){const y=4*wave(t),p=supine(16,y);p.view=68;mat(p);bentSupineLegs(p,11,-28);for(const s of [-1,1])arm(p,s,V.add(p.head,[s*8,0,-2]),[s,0,1]);shape(p,'roller',{center:[0,27,6],axis:[1,0,0],radius:6,length:43});return p;}
function legSwing(e,t){const p=model([0,0,62]),a=40*wave(t)*RAD;p.view=63;leg(p,-1,[-6,0,4],[0,1,0],0,true);legFK(p,1,[0,Math.sin(a),-Math.cos(a)],[0,Math.sin(a),-Math.cos(a)],0);arm(p,-1,[-22,28,90],[-1,0,-1]);armFK(p,1,[.1,0,-1],[.1,0,-1]);pipe(p,[[-25,30,0],[-25,30,107]],4);return p;}
function hipMachine(e,t){const close=e.number===197,q=close?1-rep(t):rep(t),p=model([0,0,36]);p.view=8;seat(p,0,29);for(const s of [-1,1]){const a=(8+35*q)*RAD,upper=[s*Math.sin(a),Math.cos(a),-.1];legFK(p,s,upper,[0,0,-1]);const k=p.j[s<0?'lk':'rk'];block(p,V.add(k,[s*(close?-5:5),0,0]),[8,15,13],'pad');pipe(p,[[s*12,0,16],V.add(k,[s*(close?-5:5),0,-3])],3);arm(p,s,[s*18,-3,29],[s,0,-1]);}block(p,[0,-20,24],[44,20,43],'machine');return p;}

function stretch(e,t){const n=e.number;let p;
 if([98,107].includes(n)){const wide=n===107;p=model([0,0,wide?57:62],wide?[0,.45,-.893]:[0,.3,-.954],wide?[0,-.893,-.45]:[0,-.954,-.3]);p.view=wide?32:72;for(const s of [-1,1]){if(wide)leg(p,s,[s*27,0,4],[0,1,0],0,true);else legFK(p,s,[0,0,-1],[0,0,-1]);arm(p,s,[s*(wide?17:9),18,3],[s,0,1]);}return p;}
 if(n===99){p=model([0,0,33],[0,.9,.436]);p.view=65;leg(p,1,[10,29,4],[0,1,0],0,true);leg(p,-1,[-10,-43,4],[0,1,0],0);for(const s of [-1,1])arm(p,s,[s*17,39,4],[s,0,-1]);mat(p);return p;}
 if(n===100){p=model([18,0,44],[0,.1,.995]);p.view=10;for(const s of [-1,1]){leg(p,s,[s*30,0,4],[0,1,0],0,true);arm(p,s,[p.hip[0]+s*10,8,50],[s,0,-1]);}return p;}
 if([101,110,114,172].includes(n)){p=supine(6);p.view=[110,114].includes(n)?35:65;mat(p);
  if(n===101){legFK(p,-1,[0,-1,0],[0,-1,0],-.35,[0,-1,0]);legFK(p,1,[0,-.2,.98],[0,-.2,.98],-.1,[0,-1,0]);for(const s of [-1,1])arm(p,s,V.add(V.mix(socket(p,1,false),p.j.rk,.55),[s*4,0,-2]),[s,-1,1]);}
  if(n===110){legFK(p,-1,[0,-.3,.954],[0,-1,0],-.1,[0,-1,0]);leg(p,1,[-6,-9,36],[1,0,1],0,false,[0,-1,0]);for(const s of [-1,1])arm(p,s,V.add(V.mix(socket(p,-1,false),p.j.lk,.55),[s*4,0,-2]),[s,-1,1]);}
  if(n===172){legFK(p,-1,[0,-1,0],[0,-1,0],-.35,[0,-1,0]);legFK(p,1,[0,.25,.968],[0,-.98,-.2],0,[0,-1,0]);for(const s of [-1,1])arm(p,s,V.add(p.j.rk,[s*4,0,-2]),[s,-1,1]);}
  if(n===114){for(const s of [-1,1]){leg(p,s,[-27+s*3,-28,4],[-1,0,1],0,false,[0,-1,0]);arm(p,s,[s*56,36,4],[s,0,1]);}}return p;}
 if(n===102){p=model([0,0,9],[0,0,1],[0,-1,0]);p.view=170;p.scale=1.8;mat(p);for(const s of [-1,1]){leg(p,s,[s*4,-29,4],[s,0,0]);p.feet.pop();p.feet.push({s,ankle:p.j[s<0?'la':'ra'],forward:[0,-1,0],up:[s,0,0],right:[0,0,s],support:false});arm(p,s,[s*4,-22,5],[s,-1,0]);}return p;}
 if(n===104){p=model([0,-10,58],[0,.75,-.661],[0,0,-1]);p.view=74;mat(p);for(const s of [-1,1]){leg(p,s,[s*9,-30,4],[0,-1,-.3],0,true);arm(p,s,[s*14,48,3],[0,-1,0]);}return p;}
 if(n===105){p=model([0,-24,19],[0,.985,-.174],[0,0,-1]);p.view=74;mat(p);for(const s of [-1,1]){legFK(p,s,[0,.94,-.342],[0,-1,0],0,[0,-1,0]);arm(p,s,[s*13,52,3],[0,0,1]);}return p;}
 if(n===106){p=model();p.view=-62;leg(p,-1,[-6,0,4],[0,1,0],0,true);legFK(p,1,[0,0,-1],[0,-.35,.937],.2,[0,-1,0]);arm(p,1,p.j.ra,[1,-1,0]);armFK(p,-1,[-.2,0,-1],[0,0,-1]);return p;}
 if([108,109].includes(n)){p=model();p.view=30;plantedLegs(p);if(n===108){arm(p,1,[-27,14,94],[0,0,-1]);arm(p,-1,V.mix(socket(p,1),p.j.re,.8),[-1,0,-1]);}else{armFK(p,1,[.05,0,1],[0,-.4,-.916]);arm(p,-1,V.add(p.j.re,[0,0,-2]),[-1,0,1]);}return p;}
 if(n===111){p=model([0,-6,57],[0,.1,.995]);p.view=50;leg(p,-1,[-10,-19,4],[0,1,0],0,true);leg(p,1,[10,15,4],[0,1,0],0,true);p.j.re=[34,10,93];p.j.rh=[34,10,116];armFK(p,-1,[-.08,0,-1],[0,0,-1]);for(const s of [-1,1])rail(p,s*35,10,145);pipe(p,[[-35,10,145],[35,10,145]],4);return p;}
 if(n===112){p=model([0,-8,57],[0,.35,.937]);p.view=70;leg(p,-1,[-9,-26,4],[0,1,0],0,true);leg(p,1,[9,14,4],[0,1,0],0,true);for(const s of [-1,1])arm(p,s,[s*17,39,89],[0,-1,0]);block(p,[0,41,68],[65,4,136],'wall');return p;}
 if(n===115){p=model();p.view=-30;leg(p,-1,[-6,0,4],[0,1,0],0,true);legFK(p,1,[0,0,-1],[0,-.95,.312],.1);for(const s of [-1,1])armFK(p,s,[s*.7,0,-.7],[s*.7,0,-.7]);return p;}
 if(n===141){p=model([0,-9,32]);p.view=65;for(const s of [-1,1]){leg(p,s,[s*12,32,4],[0,1,0],0,true);arm(p,s,[s*11,22,35],[s,0,-1]);}block(p,[0,-18,65],[65,4,130],'wall');return p;}
 if(n===170){p=model();p.view=16;plantedLegs(p);p.headUp=V.unit([.36,0,.933]);p.headRight=V.unit([.933,0,-.36]);p.head=V.add(p.shoulder,V.mul(p.headUp,15));arm(p,1,V.add(p.head,[-4,0,8]),[1,0,0]);armFK(p,-1,[-.05,0,-1],[0,0,-1]);return p;}
 if(n===171){p=model([0,0,8],[0,.5,.866],[0,.866,-.5]);p.view=73;mat(p);for(const s of [-1,1]){legFK(p,s,[0,-.998,-.069],[0,-1,0],0,[0,-1,0]);arm(p,s,[s*15,27,3],[0,-1,0]);}return p;}
 if(n===173){p=model([0,0,18],[0,.6,.8]);p.view=45;mat(p);leg(p,1,[-13,19,4],[1,1,-.5],0,false,[0,-1,0]);leg(p,-1,[-6,-54,4],[0,0,1],0,false,[0,-1,0]);for(const s of [-1,1])arm(p,s,[s*17,28,3],[s,0,-1]);return p;}
 if(n===174){p=model([0,0,9],[0,-.94,.342],[0,-.342,-.94]);p.view=68;mat(p);for(const s of [-1,1]){legFK(p,s,[0,-1,0],[0,-1,0],0,[0,-1,0]);arm(p,s,[s*9,-54,10],[s,0,1]);}return p;}
 throw Error('Unauthored stretch '+n);
}

const MOTIONS={benchPress,overheadPress,pushup,dip,chestFly,raise,pushdown,skullcrusher,pullup,pulldown,row,facePull,curl,shrug,squat,legPress,lunge,stepUp,legExtension,hinge,bridge,hyperextension,legCurl,plank,hangingRaise,rollout,crunch,twist,horizontalPress,calfRaise,gait,burpee,swing,olympic,getup,invertedRow,hollow,quadruped,superman,mountain,pullApart,pullover,jump,slam,coreLegs,stretch,bandWalk,clamshell,tricepsExtension,kickback,externalRotation,sideLunge,cardio,wrist,foamRoll,legSwing,hipMachine};
function sampleExercise(e,progress){const t=e.hold?0:clamp(progress),fn=MOTIONS[e.motion];if(!fn)throw Error('Missing motion '+e.motion);const p=fn(e,t);p.j.hip=p.hip;p.j.shoulder=p.shoulder;p.j.head=p.head;return p;}

// Revision 04: support surfaces, anatomical foot frames, cable travel, and saved review notes.
function r4Foot(p,s,toe,normal){
 const f=p.feet.find(x=>x.s===s),u=V.unit(normal),raw=V.sub(toe,V.mul(u,V.dot(toe,u)));
 if(!f||V.len(raw)<.0001)return;const front=V.unit(raw);f.up=u;f.forward=front;f.right=V.unit(V.cross(front,u));
}
function r4ShinFoot(p,s,prone=false){const k=p.j[s<0?'lk':'rk'],a=p.j[s<0?'la':'ra'],u=V.unit(V.sub(k,a)),toe=V.cross([prone?-1:1,0,0],u);r4Foot(p,s,toe,u);}
function r4Squat(e,t){
 const q=rep(t),p=squatPose(q,{smith:e.number===144,single:e.number===143,side:e.number===143}),n=e.number;
 if(n!==143){p.feet=[];p.contacts=[];for(const s of [-1,1]){const yaw=s*18*RAD;leg(p,s,[s*17,0,4.3],[s*.7,1,0],0,false,[Math.sin(yaw),Math.cos(yaw),0]);}}
 if([25,26,144].includes(n)){
  const front=n===26,c=V.add(p.shoulder,V.add(V.mul(p.forward,front?8:-5),V.mul(p.up,front?1:0)));
  if(front){for(const s of [-1,1]){const o=socket(p,s),el=V.add(o,[s*3,23,3]);p.j[s<0?'le':'re']=el;arm(p,s,V.add(c,[-s*10,0,2]),[s,.9,.1]);}p.grip='cross-arm';}
  else for(const s of [-1,1])arm(p,s,V.add(c,[s*27,0,0]),[s,-.1,-1]);
  bar(p,c);if(n===144)for(const s of [-1,1]){rail(p,s*43,-4,138);block(p,[s*43,-4,c[2]],[6,8,8],'machine');}
 }else{
  for(const s of [-1,1])arm(p,s,V.add(p.shoulder,[s*(n===78?26:6),n===78?9:15,-8]),[s,0,-1]);
  if(n===27)kb(p,V.mix(p.j.lh,p.j.rh,.5));
  if(n===142)for(const s of [-1,1]){const h=V.add(p.shoulder,[s*15,7,0]);arm(p,s,h,[s,0,-1]);dumbbell(p,h,[0,1,0]);}
  if(n===78)for(const s of [-1,1])cable(p,[s*22,0,1.5],p.j[s<0?'lh':'rh'],'band');
 }
 if([140,143].includes(n))block(p,[0,-20,13],[43,30,26],'wood');return p;
}
function r4Lunge(e,t){
 const n=e.number,q=rep(t),bulg=n===30,reverse=n===59,split=[30,145].includes(n),front=split?20:reverse?0:40*q,hipY=split?mix(0,-9,q):reverse?-29*q:11*q;
 const p=model([0,hipY,(split?57:61)-((split?57:61)-33.3)*q],[0,.07,.9975]);p.view=65;
 leg(p,1,[10,front,4.3],[0,1,0]);
 if(bulg){const end=[-10,-34,30.3];leg(p,-1,end,[0,1,0],0,false,[0,-1,0]);block(p,[-10,-43,13],[34,32,26],'wood');}
 else{const pitch=1.1,az=9*Math.sin(pitch)+4.3*Math.cos(pitch),back=split?-28:reverse?-58*q:-18;leg(p,-1,[-10,back,az],[0,1,0],pitch);}
 hangArms(p);if([31,59].includes(n))loads(p,e);return p;
}
function r4StepUp(e,t){
 if(e.number===166)return r4Stairs(e,t);
 const q=keyValue(t,[[0,0],[.12,0],[.48,1],[.62,1],[1,0]]),lift=keyValue(t,[[0,0],[.16,0],[.3,1],[.77,1],[.96,0],[1,0]]),p=model([0,-7+20*q,56+20*q]);p.view=68;
 leg(p,1,[10,20,26.3],[0,1,0]);
 // Lift the trailing sole above the front edge before carrying it over the box.
 const y=keyValue(t,[[0,-16],[.3,-16],[.48,8],[.62,8],[.76,-16],[1,-16]]),z=4.3+32*lift;
 leg(p,-1,[-10,y,z],[0,1,0]);block(p,[0,20,11],[47,34,22],'wood');hangArms(p);return p;
}
function r4LegPress(e,t){
 const q=rep(t),travel=V.unit([0,1,1]),backUp=V.unit([0,-1,1]),p=model([0,-30,31],backUp,[0,1,1]);p.view=68;
 const normal=V.mul(travel,-1),toe=backUp,plate=V.add([0,-30,31],V.mul(travel,57-23*q));
 const basis={right:[1,0,0],forward:toe,up:normal};
 // Backrest and foot plate share a plane; both are perpendicular to the rails.
 block(p,V.add(p.hip,V.add(V.mul(backUp,14),V.mul(normal,7))),[33,49,6],'pad',basis);
 block(p,[0,-34,24],[33,24,5],'pad');pipe(p,[[0,-34,3],[0,-34,21]],5);
 for(const s of [-1,1]){
  const sole=V.add(plate,[s*12,0,0]),ankle=V.add(sole,V.add(V.mul(normal,6.3),V.mul(toe,-2)));
  leg(p,s,ankle,[0,-1,1]);r4Foot(p,s,toe,normal);arm(p,s,[s*21,-34,23],[s,0,-1]);
  pipe(p,[[s*32,-38,14],[s*32,47,99]],4);pipe(p,[[s*21,-34,23],[s*21,-22,23]],3,'grip');
 }
 block(p,plate,[50,36,4],'metal',basis);for(const s of [-1,1]){pipe(p,[V.add(plate,[s*25,0,0]),V.add(plate,[s*34,0,0])],5);shape(p,'cylinder',{center:V.add(plate,[s*35,0,0]),axis:[1,0,0],radius:13,length:5,color:'weight'});}return p;
}
function r4Row(e,t){
 const n=e.number,q=rep(t);
 if(n===17){const p=model([14,-8,57],[0,.94,.342]);p.view=-55;bench(p,[0,-28,32],[0,51,32],21);
  leg(p,1,[27,-14,4.3],[0,1,0]);p.j.lk=[0,-21,38];p.j.la=[0,-49,38];foot(p,-1,p.j.la,0,[0,-1,0]);
  arm(p,-1,[0,40,38],[-1,0,-1]);const sh=socket(p,1);arm(p,1,V.mix(V.add(sh,[6,0,-45.8]),V.add(sh,[6,-10,-8]),q),[.15,-1,0]);dumbbell(p,p.j.rh,[0,1,0]);return p;}
 if(n===132){const up=V.unit([0,.866,.5]),p=model([0,-9,51],up,[0,.5,-.866]);p.view=135;
  bench(p,[0,-6,43],[0,44,72],23);
  // A narrow chest pad ends in front of the pelvis; legs straddle the support.
  for(const s of [-1,1]){leg(p,s,[s*23,-39,4.3],[s*.6,-1,0]);const sh=socket(p,s);arm(p,s,V.mix(V.add(sh,[s*10,0,-45.5]),V.add(sh,[s*10,-13,-8]),q),[s*.2,-1,0]);dumbbell(p,p.j[s<0?'lh':'rh'],[0,1,0]);}return p;}
 if(n===192){const p=model([0,-9,56],[0,.86,.51]);p.view=135;plantedLegs(p,19);
  const anchor=[0,-65,3],h=[0,24+7*q,29+24*q],axis=V.unit(V.sub(h,anchor)),tip=V.add(h,V.mul(axis,17));
  for(const s of [-1,1])arm(p,s,V.add(h,[s*8,0,0]),[s,-1,0]);pipe(p,[anchor,tip],3.5);pipe(p,[p.j.lh,p.j.rh],3,'grip');shape(p,'cylinder',{center:V.add(h,V.mul(axis,11)),axis,radius:14,length:6,color:'weight'});block(p,anchor,[23,15,6],'metal');return p;}
 return row(e,t);
}
function r4RearFly(e,t){const q=rep(t),p=model([0,-10,38],[0,.9,.436],[0,.436,-.9]);p.view=135;bench(p,[0,-38,31],[0,0,31],27);
 for(const s of [-1,1]){leg(p,s,[s*17,25,4.3],[s*.15,1,0]);const a=(7+76*q)*RAD,dir=V.add(V.mul(p.right,s*Math.sin(a)),V.mul(p.forward,Math.cos(a)));armFK(p,s,dir,V.add(dir,V.mul(p.up,.08)));dumbbell(p,p.j[s<0?'lh':'rh']);}return p;}
function r4Curl(e,t){const p=model();p.view=30;plantedLegs(p);for(const s of [-1,1]){const q=rep(t+(s>0?.5:0)),a=(8+120*q)*RAD;armFK(p,s,[s*.12,0,-1],[0,Math.sin(a),-Math.cos(a)]);dumbbell(p,p.j[s<0?'lh':'rh'],[0,0,1]);}p.grip='neutral';return p;}
function r4Arnold(e,t){const q=rep(t),p=model();p.view=30;plantedLegs(p);for(const s of [-1,1]){
 const o=socket(p,s),el0=V.add(o,[-s*3,16,-17.5]),h0=V.add(el0,[0,0,23]),h1=V.add(o,[s*4,3,46.5]);arm(p,s,V.mix(h0,h1,q),[s,1,-.5]);
 // Oriented grip marker distinguishes pronation through the complete half turn.
 const theta=(1-q)*Math.PI,axis=[Math.cos(theta),s*Math.sin(theta),0],h=p.j[s<0?'lh':'rh'];dumbbell(p,h,axis);pipe(p,[V.add(h,V.mul(axis,3)),V.add(h,V.add(V.mul(axis,3),[0,0,3]))],1.5,'grip');
 }return p;}
function r4Hyper(e,t){const q=rep(t),a=(45+70*q)*RAD,up=[0,Math.sin(a),Math.cos(a)],p=model([0,0,54],up,[0,Math.cos(a),-Math.sin(a)]);p.view=65;
 const legdir=V.unit([0,-1,-1]),padup=V.unit([0,1,-1]);
 for(const s of [-1,1]){legFK(p,s,legdir,legdir);r4Foot(p,s,[0,1,-1],V.mul(legdir,-1));arm(p,s,V.add(p.shoulder,[s*4,8,-10]),[s,0,-1]);}
 const basis={right:[1,0,0],forward:V.mul(legdir,-1),up:padup};block(p,V.add(p.hip,V.add(V.mul(legdir,11),V.mul(padup,7))),[29,23,8],'pad',basis);
 pipe(p,[[0,-5,37],[0,-40,3]],6);block(p,[0,-41,13],[35,12,8],'pad');block(p,[0,-43,5],[41,24,4],'metal',basis);pipe(p,[[-24,-40,2],[24,-40,2]],5);return p;}
function r4Plank(e,t){
 if([42,161].includes(e.number)){const p=plank(e,t);for(const s of [-1,1])r4Foot(p,s,e.number===161?[0,-1,0]:[0,-1,0],[-1,0,0]);if(e.number===161)p.view=-90;return p;}
 const knee=e.number===160,pitch=1.08,ankleZ=9*Math.sin(pitch)+4.3*Math.cos(pitch),uz=knee?23/65:(27-ankleZ)/94,up=[0,Math.sqrt(1-uz*uz),uz],hip=knee?V.add([0,-24,4],V.mul(up,29)):V.add([0,-71,ankleZ],V.mul(up,58)),p=model(hip,up,[0,0,-1]);p.view=75;mat(p);
 for(const s of [-1,1]){const o=socket(p,s),el=V.add(o,[0,0,-24]);p.j[s<0?'le':'re']=el;p.j[s<0?'lh':'rh']=V.add(el,[0,23,0]);p.contacts.push({kind:'elbow',point:el,height:3});
  if(knee){const k=[s*6,-24,4];p.j[s<0?'lk':'rk']=k;p.j[s<0?'la':'ra']=V.add(k,[0,-28,7.55]);foot(p,s,p.j[s<0?'la':'ra'],.25,[0,-1,0]);p.contacts.push({kind:'knee',point:k,height:4});}
  else legFK(p,s,V.mul(up,-1),V.mul(up,-1),pitch);
 }
 return p;
}
function r4Rollout(e,t){const q=rep(t),a=(15+50*q)*RAD,legUp=[0,Math.sin(a),Math.cos(a)],hip=V.add([0,-30,4.3],V.mul(legUp,29)),torso=V.unit([0,1,-.12+.08*q]),p=model(hip,torso,[0,0,-1]);p.view=75;mat(p);
 for(const s of [-1,1]){p.j[s<0?'lk':'rk']=[s*6,-30,4.3];p.j[s<0?'la':'ra']=[s*6,-58,11.85];foot(p,s,p.j[s<0?'la':'ra'],.25,[0,-1,0]);const o=socket(p,s),dy=Math.sqrt(46.8**2-(o[2]-9)**2);arm(p,s,[s*13,o[1]+dy,9],[0,0,1]);}
 const h=V.mix(p.j.lh,p.j.rh,.5);shape(p,'wheel',{center:h,radius:9,axis:[1,0,0]});pipe(p,[p.j.lh,p.j.rh],3,'grip');return p;}
function r4Swing(e,t){const q=rep(t),a=65*(1-q)*RAD,p=model([0,-17*(1-q),54+5*q],[0,Math.sin(a),Math.cos(a)]);p.view=65;
 for(const s of [-1,1])leg(p,s,[s*22,0,4.3],[s*.4,1,0]);const angle=(-38+128*q)*RAD;for(const s of [-1,1]){const dir=[-s*.17,Math.sin(angle),-Math.cos(angle)];armFK(p,s,dir,dir);}kb(p,V.mix(p.j.lh,p.j.rh,.5));return p;}
function r4Snatch(e,t){
 const hip=keyValue(t,[[0,[0,-18,38]],[.19,[0,-8,50]],[.3,[0,0,60.5]],[.44,[0,-13,34]],[.61,[0,0,60.5]],[.7,[0,0,60.5]],[.84,[0,-8,50]],[1,[0,-18,38]]]);
 const a=keyValue(t,[[0,58],[.19,25],[.3,0],[.44,10],[.61,0],[.7,0],[.84,25],[1,58]])*RAD,p=model(hip,[0,Math.sin(a),Math.cos(a)]);p.view=55;plantedLegs(p,17);
 const offset=keyValue(t,[[0,-40],[.19,-37],[.3,-19],[.44,40.5],[.61,40.5],[.7,40.5],[.84,-37],[1,-40]]),c=V.add(p.shoulder,[0,0,offset]);
 let front=5;for(let i=0;i<31;i++){const axis=V.mix(p.hip,p.shoulder,i/30),w=1-ease((Math.abs(axis[2]-c[2])-7)/8);front=Math.max(front,mix(5,axis[1]+13,w));}
 const hw=1-ease((Math.abs(c[2]-p.head[2])-14)/10);front=Math.max(front,mix(5,p.head[1]+14,hw));c[1]=mix(front,3,ease((offset-32)/8));
 for(const s of [-1,1])arm(p,s,V.add(c,[s*32,0,0]),[s,0,0]);bar(p,c,[1,0,0],48);return p;
}
function r4Sprint(e,t){const a=t*2*Math.PI,p=model([0,0,58+2*Math.cos(2*a)],[0,.16,.987]);p.view=75;
 for(const s of [-1,1]){const u=(t+(s>0?.5:0))%1,stance=u<.33,phase=stance?u/.33:(u-.33)/.67,y=stance?mix(9,-17,phase):keyValue(phase,[[0,-17],[.42,-18],[.73,13],[1,9]]),z=stance?4.3:4.3+29*Math.sin(Math.PI*phase);
 leg(p,s,[s*8,y,z],[0,1,0],stance?0:.5*Math.sin(Math.PI*phase));const angle=.6*Math.sin(a+(s<0?Math.PI:0));armFK(p,s,[0,Math.sin(angle),-Math.cos(angle)],[0,Math.cos(angle),Math.sin(angle)]);}return p;
}
function r4Wall(e,t){const q=rep(t),angle=(14+13*q)*RAD,ankle=[0,-32,4.3],up=[0,Math.sin(angle),Math.cos(angle)],hip=V.add(ankle,V.mul(up,58)),p=model(hip,up,[0,1,0]);p.view=135;
 block(p,[0,37,64],[75,4,128],'wall');for(const s of [-1,1]){legFK(p,s,V.mul(up,-1),V.mul(up,-1));arm(p,s,[s*19,32.5,87],[s,-1,-.3]);}return p;}
function r4FacePull(e,t){const q=rep(t),p=model();p.view=135;plantedLegs(p);for(const s of [-1,1])arm(p,s,V.mix([s*9,44,100],[s*27,10,104],q),[s,0,.3]);
 const origin=[0,88,108],h=V.mix(p.j.lh,p.j.rh,.5),fork=V.add(h,[0,8,0]);if(e.number===136)rail(p,0,88,135);else station(p,origin);
 cable(p,origin,fork,e.number===136?'band':'cable',false);for(const s of [-1,1])cable(p,fork,p.j[s<0?'lh':'rh'],e.number===136?'band':'rope',false);return p;}
function r4CableRaise(e,t){const p=model(),q=rep(t);p.view=20;plantedLegs(p);for(const s of [-1,1]){const angle=(8+79*q)*RAD,dir=[s*Math.sin(angle),.35,-Math.cos(angle)];armFK(p,s,dir,dir);const origin=[-s*68,25,7];station(p,origin);cable(p,origin,p.j[s<0?'lh':'rh']);}return p;}
function r4SinglePulldown(e,t){const q=rep(t),p=model();p.view=135;plantedLegs(p,12);armFK(p,-1,[-.2,0,-1],[0,.2,-1]);const o=socket(p,1);arm(p,1,V.mix(V.add(o,[7,21,41]),V.add(o,[9,12,-17]),q),[1,.1,-.2]);const a=[25,77,158];station(p,a);cable(p,a,p.j.rh);return p;}
function r4Slam(e,t){
 const hinge=keyValue(t,[[0,0],[.18,0],[.4,1],[.5,1],[.68,.65],[.88,0],[1,0]]),bend=keyValue(t,[[0,0],[.43,0],[.66,1],[.8,0],[1,0]]),a=hinge*60*RAD,p=model([0,-10*hinge,60-25*bend],[0,Math.sin(a),Math.cos(a)]);p.view=65;plantedLegs(p,17);
 const angle=keyValue(t,[[0,175],[.18,175],[.38,-15],[.5,-15],[.68,-15],[.88,175],[1,175]])*RAD;for(const s of [-1,1])armFK(p,s,[-s*.18,Math.sin(angle),-Math.cos(angle)],[-s*.18,Math.sin(angle),-Math.cos(angle)]);
 const held=V.mix(p.j.lh,p.j.rh,.5),release=.29,catchTime=.66;let ball=held;
 if(t>=release&&t<=catchTime){const h=keyValue(release,[[0,0],[.18,0],[.4,1]]),ap=60*h*RAD,rp=model([0,-10*h,60],[0,Math.sin(ap),Math.cos(ap)]),ang=keyValue(release,[[.18,175],[.38,-15]])*RAD,rv=V.unit([0,Math.sin(ang),-Math.cos(ang)]),start=V.add(rp.shoulder,V.mul(rv,46.25));ball=keyValue(t,[[release,start],[.43,[0,34,8]],[.59,[0,34,8]],[catchTime,held]]);}
 shape(p,'ball',{center:ball,radius:8});return p;
}
function r4Core(e,t){const n=e.number;
 if(n===180){const p=model([0,0,9],[0,.866,.5],[0,-.5,.866]);p.view=75;mat(p);for(const s of [-1,1]){const o=socket(p,s),el=[s*13,o[1]+2,4];p.j[s<0?'le':'re']=el;p.j[s<0?'lh':'rh']=V.add(el,[0,-23,0]);const q=rep(t+(s>0?.5:0)),a=(15+65*q)*RAD,b=15*(1-q)*RAD;legFK(p,s,[0,-Math.cos(a),Math.sin(a)],[0,-Math.cos(b),Math.sin(b)]);r4ShinFoot(p,s);}return p;}
 const p=coreLegs(e,t);for(const s of [-1,1]){r4ShinFoot(p,s);if(n===181){const f=p.feet.find(f=>f.s===s),blend=ease((f.ankle[2]-4)/10);r4Foot(p,s,V.mix([0,-1,0],f.forward,blend),V.mix([0,0,1],f.up,blend));}}if(n===183)p.view=90;return p;
}
function r4Heel(e,t){const p=supine(7),q=wave(t);mat(p);articulatedCrunch(p,.55);bentSupineLegs(p,14,-15);const shift=7*q;p.spine=p.spine.map((v,i)=>V.add(v,[shift*i/3,0,0]));p.shoulder=p.spine.at(-1);p.head=V.add(p.head,[shift,0,0]);p.view=45;
 for(const s of [-1,1]){const reach=.5+.5*s*q,target=V.mix(V.add(socket(p,s),[s*3,-36,-5]),[s*17,-10,5],reach);const o=socket(p,s),d=V.sub(target,o);arm(p,s,V.add(o,V.mul(V.unit(d),Math.min(46.8,V.len(d)))),[s,-1,.2]);}return p;
}
function r4Stretch(e,t){const p=model([0,0,9],[0,-.64,.768],[0,-.768,-.64]);p.view=68;mat(p);for(const s of [-1,1]){legFK(p,s,[0,-1,0],[0,-1,0]);r4ShinFoot(p,s);arm(p,s,[s*9,-52,13],[s,-1,1]);}return p;}
function r4Jack(e,t){const spread=rep(t),hop=8*Math.sin(2*Math.PI*t)**2,p=model([0,0,58+hop]);p.view=10;for(const s of [-1,1]){leg(p,s,[s*(7+20*spread),0,4.3+hop],[s*.15,1,0]);const a=(5+162*spread)*RAD;armFK(p,s,[s*Math.sin(a),0,-Math.cos(a)],[s*Math.sin(a),0,-Math.cos(a)]);}return p;}
function r4Stairs(e,t){const p=model([0,0,61]);p.view=65;const belt=(t*2)%1;
 for(let k=-2;k<=5;k++){const y=(k-belt)*19,z=15+(k-belt)*12;if(z<1||z>65)continue;block(p,[0,y,z-1.5],[49,19,3],'metal');block(p,[0,y+9,z-7.5],[49,2,12],'machine');}
 block(p,[0,20,3],[65,110,6],'machine');for(const s of [-1,1]){const u=(t+(s>0?.5:0))%1,stance=u<.5,v=stance?u/.5:(u-.5)/.5,y=stance?mix(15,-4,v):mix(-4,15,ease(v)),z=stance?mix(31.3,19.3,v):mix(19.3,31.3,ease(v))+20*Math.max(0,Math.sin(Math.PI*v))**.6;
 leg(p,s,[s*12,y,z],[0,1,0]);arm(p,s,[s*25,40,104],[s,-1,0]);pipe(p,[[s*28,-30,3],[s*28,-10,92],[s*28,45,110]],4);}block(p,[0,47,112],[42,9,15],'console');return p;}
const R4MOTIONS={17:r4Row,19:r4FacePull,21:r4Curl,23:r4RearFly,25:r4Squat,26:r4Squat,27:r4Squat,28:r4LegPress,30:r4Lunge,31:r4Lunge,32:r4StepUp,39:r4Hyper,41:r4Plank,42:r4Plank,44:r4Rollout,53:r4Swing,55:r4Snatch,59:r4Lunge,78:r4Squat,80:r4Arnold,88:r4Sprint,90:r4Slam,124:r4Wall,131:r4CableRaise,132:r4Row,136:r4FacePull,145:r4Lunge,93:r4Core,158:r4Core,160:r4Plank,161:r4Plank,166:r4Stairs,169:r4Jack,174:r4Stretch,178:r4Core,179:r4Core,180:r4Core,181:r4Core,182:r4Core,183:r4Core,184:r4Core,185:r4Heel,192:r4Row,193:r4SinglePulldown};
function r4Finish(p,e,t){
 if(e.number===57){const u=t<=.6?t/.6:(1-t)/.4,a=Math.PI*(1-ease((u-.4)/.35));for(const s of [-1,1])r4Foot(p,s,[Math.sin(a),Math.cos(a),0],[0,0,1]);}
 if(e.number===65)r4ShinFoot(p,1);
 if(e.number===118)for(const s of [-1,1])r4Foot(p,s,[0,-1,0],[1,0,0]);
 if(e.number===33){for(const s of [-1,1])r4ShinFoot(p,s,true);p.objects=p.objects.filter(o=>!(o.type==='box'&&o.size[0]===43));const a=V.mix(p.j.la,p.j.ra,.5),k=V.mix(p.j.lk,p.j.rk,.5);shape(p,'cylinder',{center:V.add(a,V.add(V.mul(V.unit(V.sub(k,a)),10),[0,4,0])),axis:[1,0,0],radius:4.5,length:43,color:'pad'});}
 if(e.number===164)for(const o of p.objects)if(o.type==='box'&&o.size[0]===35&&o.size[2]===42)o.size[0]=15;
 if(e.number===135){const band=p.objects.find(o=>o.type==='line'&&o.color==='band');if(band)band.points=[[43,15,144],p.j.ra];}
 if([60,105,107,113].includes(e.number)){const min=p.head[2]-9*Math.abs(p.up[2])-7*Math.abs(p.forward[2])-8.5*Math.abs(p.right[2]);if(min<.5)p.head[2]+=.5-min;}
 if(e.number===120)for(const o of p.objects)if(o.type==='dumbbell')o.axis=[0,1,0];
 if(e.number===134)p.objects=p.objects.filter(o=>!(o.type==='line'&&o.points.some(v=>v[1]===-18)&&o.points.every(v=>Math.abs(v[0])<8)));
 if([40,63,101,110,172,186].includes(e.number))for(const s of [-1,1])r4ShinFoot(p,s,e.number===40);return r4CableTowers(p,e,t);
}
// Guided cable towers: the working cable and the lifted stack share one continuous path.
const R4_ORIGINALS={...MOTIONS},r4CableRanges=new Map();
function r4CableTowers(p,e,t){
 if([7,121].includes(e.number))return p;
 const pulleys=p.objects.filter(o=>o.type==='pulley');if(!pulleys.length)return p;
 const bandOnly=[72,75,122,153].includes(e.number);
 for(let j=p.objects.length-1;j>=0;j--){const o=p.objects[j];if(o.type!=='pulley')continue;const origin=o.center;
  const connected=p.objects.find(x=>x.type==='line'&&['cable','band'].includes(x.color)&&V.len(V.sub(x.points[0],origin))<.01);if(!connected)continue;
  const length=V.len(V.sub(connected.points.at(-1),origin)),key=e.id+'|'+origin.join(',');
  if(!r4CableRanges.has(key)){const lengths=[];for(let k=0;k<=48;k++){const pose=(R5MOTIONS[e.number]||R4MOTIONS[e.number]||R4_ORIGINALS[e.motion])(e,k/48);const line=pose.objects.find(x=>x.type==='line'&&['cable','band'].includes(x.color)&&V.len(V.sub(x.points[0],origin))<.01);if(line)lengths.push(V.len(V.sub(line.points.at(-1),origin)));}r4CableRanges.set(key,Math.min(...lengths));}
  // station() contributes exactly its column, stack, base and pulley, in this order.
  p.objects.splice(j-3,4);const x=origin[0],y=origin[1]+12,top=Math.max(150,origin[2]+8);
  if(bandOnly){rail(p,x,origin[1],top);continue;}
  const lift=clamp(length-r4CableRanges.get(key),0,65),stack=[x,y,29+lift];
  for(const s of [-1,1])pipe(p,[[x+s*10,y,4],[x+s*10,y,top]],2.4);
  block(p,[x,y,3],[35,32,5],'metal');block(p,stack,[16,12,40],'machine');
  for(let z=-15;z<=15;z+=6)pipe(p,[[x-8,y-6.1,stack[2]+z],[x+8,y-6.1,stack[2]+z]],.6,'grip');
  const upper=[x,y,top-4];cable(p,V.add(stack,[0,0,20]),upper,'cable',false);cable(p,upper,origin,'cable',false);shape(p,'pulley',{center:upper});shape(p,'pulley',{center:origin});
 }
 return p;
}

// Camera framing and animation use the same revised geometry.
for(const key of Object.keys(MOTIONS)){const original=MOTIONS[key];MOTIONS[key]=(e,t)=>r4Finish((R4MOTIONS[e.number]||original)(e,t),e,t);}

// Revision 05: refinements from the user's next review batch.
function r5MoveSpine(p,hip,up,forward=[0,1,0]){const m=model(hip,up,forward);for(const key of ['hip','up','forward','spine','shoulder','head'])p[key]=m[key];}
function r5Shrug(e,t){const q=rep(t),p=model();p.view=18;plantedLegs(p);p.armSockets={};for(const s of [-1,1]){p.armSockets[s]=V.add(p.shoulder,[s*13,0,3*q]);block(p,V.add(p.shoulder,[s*10,0,1.2*q]),[9,11,3+q],'shirt');armFK(p,s,[s*.08,0,-1],[s*.03,0,-1]);dumbbell(p,p.j[s<0?'lh':'rh'],[0,1,0]);}return p;}
function r5FrontSquat(e,t){const p=r4Squat(e,t);p.objects=p.objects.filter(o=>o.type!=='bar');for(const s of [-1,1])armFK(p,s,[-s*.25,.96,.08],[-s*.78,-.6,.2]);bar(p,V.add(p.shoulder,[0,9,5]));p.grip='cross-arm';return p;}
function r5BandSquat(e,t){const p=r4Squat(e,t);p.objects=p.objects.filter(o=>!(o.type==='line'&&o.color==='band')&&o.type!=='handle');for(const s of [-1,1]){armFK(p,s,[s*.3,.28,-.91],[s*.02,0,1]);cable(p,[s*22,0,1.5],p.j[s<0?'lh':'rh'],'band');}return p;}
function r5Pulldown(e,t){const q=rep(t),p=model([0,0,35]);p.view=135;bench(p,[0,-40,28],[0,17,28],32);for(const s of [-1,1]){leg(p,s,[s*12,32,4],[0,1,0],0,true);arm(p,s,[s*25,9,mix(115,76,q)],[s*.7,0,-1]);}const origin=[0,58,146];station(p,origin);pipe(p,[V.add(p.j.lh,[-9,0,2]),p.j.lh,p.j.rh,V.add(p.j.rh,[9,0,2])],3,'grip');cable(p,origin,V.mix(p.j.lh,p.j.rh,.5),'cable',false);block(p,[0,22,40],[36,10,5],'pad');return p;}
function r5CableRow(e,t){const p=row(e,t),o=p.objects.find(o=>o.type==='pulley');o.center[2]=60;return p;}
function r5FacePull(e,t){const q=rep(t),p=model();p.view=135;plantedLegs(p);for(const s of [-1,1])arm(p,s,V.mix([s*9,44,101],[s*19,13,117],q),[s,0,.3]);const origin=[0,88,103],fork=V.add(V.mix(p.j.lh,p.j.rh,.5),[0,8,0]);station(p,origin);cable(p,origin,fork,'cable',false);for(const s of [-1,1])cable(p,fork,p.j[s<0?'lh':'rh'],'rope',false);return p;}
function r5Preacher(e,t){const q=rep(t),p=model([0,-9,35]);p.view=30;seat(p,-9,28);plantedLegs(p,12,24);const down=V.unit([0,.72,-.694]),normal=V.unit([0,.694,.72]);
 // The upper arms sit on the near face of a sloped pad; the elbows clear its lower edge.
 block(p,[0,-5,57.85],[39,25,5],'pad',{right:[1,0,0],forward:down,up:normal});pipe(p,[[0,10,3],[0,11,57]],4);
 for(const s of [-1,1]){const angle=(1+120*q)*RAD;armFK(p,s,down,[0,Math.sin(angle),-Math.cos(angle)]);dumbbell(p,p.j[s<0?'lh':'rh'],[1,0,0]);}return p;}
function r5Hack(e,t){const q=rep(t),up=V.unit([0,-.35,.937]),front=V.unit([0,.937,.35]),hip=V.add([0,0,58],V.mul(up,-26*q)),p=model(hip,up,front);p.view=65;
 for(const s of [-1,1]){leg(p,s,[s*13,25,8.3],[0,1,0]);arm(p,s,V.add(p.shoulder,[s*24,9,-9]),[s,0,-1]);const a=[s*32,12,4],b=V.add(a,V.mul(up,132));pipe(p,[a,b],4);block(p,V.add(p.shoulder,V.add([s*19,0,0],V.mul(front,3))),[10,18,8],'pad',{right:[1,0,0],forward:front,up});}
 block(p,V.add(hip,V.add(V.mul(up,17),V.mul(front,-8))),[37,6,48],'pad',{right:[1,0,0],forward:front,up});block(p,[0,25,2],[55,42,4],'metal');return p;}
function r5Bulgarian(e,t){const q=rep(t),p=model([0,mix(0,-9,q),57-23.7*q],[0,.07,.9975]);p.view=65;leg(p,1,[10,20,4.3],[0,1,0]);const end=[-10,-26,30.3];leg(p,-1,end,[0,1,0],0,false,[0,-1,0]);
 // The heel is at the near edge; the shin stays entirely in front of the box.
 block(p,[-10,-46,13],[34,40,26],'wood');hangArms(p);return p;}
function r5Step(e,t){const u=t<=.55?t/.55:(1-t)/.45,q=ease(u),rise=22*q,hip=[0,-17+37*q,62.161903+rise],p=model(hip);p.view=68;
 leg(p,1,[10,20,26.3],[0,1,0]);const trailingY=mix(-17,20,q),clearance=22*Math.sin(Math.PI*q),z=4.3+rise+clearance;leg(p,-1,[-10,trailingY,z],[0,1,0]);block(p,[0,20,11],[47,34,22],'wood');hangArms(p);return p;}
function r5HingeBar(e,t){const p=hinge(e,t);p.objects=p.objects.filter(o=>o.type!=='bar');const n=e.number;
 if(n===38){p.feet=[];p.contacts=[];for(const s of [-1,1])leg(p,s,[s*8,0,4],[0,1,0],0,true);const c=V.add(p.shoulder,V.add(V.mul(p.up,3),V.mul(p.forward,-7.5)));for(const s of [-1,1])arm(p,s,V.add(c,[s*25,0,0]),[s,0,-1]);bar(p,c);return p;}
 const z=p.shoulder[2]-44.6;let y=6;for(const s of [-1,1]){const h=socket(p,s,false),k=p.j[s<0?'lk':'rk'],a=p.j[s<0?'la':'ra'];for(const [u,v]of [[h,k],[k,a]]){const w=clamp((z-u[2])/(v[2]-u[2]||1));const point=V.mix(u,v,w);const weight=1-ease((Math.abs(point[2]-z)-4)/8);y=Math.max(y,mix(6,point[1]+7,weight));}}
 y=Math.max(y,6);const c=[0,y,z];for(const s of [-1,1])arm(p,s,V.add(c,[s*20,0,0]),[s,0,-1]);bar(p,c);return p;}
function r5Bridge(e,t){const p=bridge(e,t);if(e.number===36){const matObject=p.objects[0];p.objects=p.objects.filter(o=>o.type==='bar');p.objects.unshift(matObject);block(p,[0,34,28],[75,28,5],'pad');for(const s of [-1,1]){pipe(p,[[s*28,34,3],[s*28,34,25]],4);pipe(p,[[s*28,22,2],[s*28,46,2]],4);}const c=V.add(p.hip,[0,0,10]);for(const s of [-1,1])arm(p,s,V.add(c,[s*17,0,0]),[s,0,-1]);}
 else for(const s of [-1,1])armFK(p,s,[s*.348,-.929,-.125],[s*.35,-.937,0]);return p;}
function r5SidePlank(e,t){const p=plank(e,t);for(const s of [-1,1]){const a=p.j[s<0?'la':'ra'],k=p.j[s<0?'lk':'rk'];r4Foot(p,s,[1,0,0],V.sub(k,a));const f=p.feet.find(f=>f.s===s),bottom=a[2]-4.3*f.up[2]-4.2*Math.abs(f.right[2]);if(s<0&&bottom<0){a[2]-=bottom;p.j.lk=V.mix(socket(p,s,false),a,.5);}}return p;}
function r5Rollout(e,t){const q=rep(t),a=60*q*RAD,hip=V.add([0,-30,4.3],[0,29*Math.sin(a),29*Math.cos(a)]),angle=(38.8-40.8*q)*RAD,up=[0,Math.cos(angle),Math.sin(angle)],p=model(hip,up,[0,0,-1]);p.view=75;mat(p);
 for(const s of [-1,1]){p.j[s<0?'lk':'rk']=[s*6,-30,4.3];p.j[s<0?'la':'ra']=[s*6,-58,11.85];foot(p,s,p.j[s<0?'la':'ra'],.25,[0,-1,0]);const o=socket(p,s),dy=Math.sqrt(Math.max(0,46.9**2-(o[2]-9)**2));arm(p,s,[s*13,o[1]+dy,9],[0,0,1]);}const h=V.mix(p.j.lh,p.j.rh,.5);shape(p,'wheel',{center:h,radius:9,axis:[1,0,0]});pipe(p,[p.j.lh,p.j.rh],3,'grip');return p;}
function r5CableCrunch(e,t){const q=rep(t),p=model([0,-15,33]);p.view=65;mat(p);const points=[p.hip];let at=p.hip;for(const angle of [mix(5,65,q),mix(10,100,q),mix(10,145,q)]){at=V.add(at,[0,12*Math.sin(angle*RAD),12*Math.cos(angle*RAD)]);points.push(at);}setSpine(p,points);p.forward=[0,p.up[2],-p.up[1]];p.head=V.add(p.shoulder,V.add(V.mul(p.up,15),V.mul(p.forward,3)));
 for(const s of [-1,1]){legFK(p,s,[0,0,-1],[0,-1,0],0,[0,-1,0]);arm(p,s,V.add(p.head,V.add(V.mul(p.forward,11.5),[s*14,0,0])),[s,-.2,0]);}
 const origin=[0,70,145],fork=V.add(p.head,[0,0,20]);station(p,origin);cable(p,origin,fork,'cable',false);for(const s of [-1,1])pipe(p,[fork,V.add(p.head,[s*17,0,14]),p.j[s<0?'lh':'rh']],1.3,'rope');return p;}
function r5Arnold(e,t){const q=rep(t),p=model();p.view=30;plantedLegs(p);for(const s of [-1,1]){const o=socket(p,s),bottom=V.add(o,[-s*5,17,4]),top=V.add(o,[s*3,3,46.5]);arm(p,s,V.mix(bottom,top,q),[-s*.2,1,-.9]);const theta=(1-q)*Math.PI,axis=[Math.cos(theta),s*Math.sin(theta),0],h=p.j[s<0?'lh':'rh'];dumbbell(p,h,axis);pipe(p,[V.add(h,V.mul(axis,3)),V.add(h,V.add(V.mul(axis,3),[0,0,3]))],1.5,'grip');}return p;}
function r5Sprint(e,t){const p=r4Sprint(e,t),a=t*2*Math.PI;for(const s of [-1,1]){const phase=a+(s<0?Math.PI:0),theta=-.65*Math.sin(phase),bend=(80+12*Math.cos(phase))*RAD;armFK(p,s,[0,Math.sin(theta),-Math.cos(theta)],[0,Math.sin(theta+bend),-Math.cos(theta+bend)]);}return p;}
function r5HighKnees(e,t){const p=model([0,0,60]);p.view=65;for(const s of [-1,1]){const u=(t+(s>0?.5:0))%1,q=u<.5?rep(u*2):0;leg(p,s,[s*8,0,4.3+35*q],[0,1,0]);const a=-.5*Math.sin(2*Math.PI*u),bend=90*RAD;armFK(p,s,[0,Math.sin(a),-Math.cos(a)],[0,Math.sin(a+bend),-Math.cos(a+bend)]);}return p;}
function r5Bike(e,t){const p=stationaryBike(e,1-t);p.feet=[];p.contacts=[];for(const s of [-1,1]){const a=-t*2*Math.PI+(s>0?Math.PI:0),pedal=[s*13,1+12*Math.cos(a),20+12*Math.sin(a)],end=V.add(pedal,[0,-2,5.3]);leg(p,s,end,[s*.2,1,0]);}
 p.objects=p.objects.filter(o=>!(o.type==='box'&&o.color==='grip')&&!(o.type==='line'&&o.width===2.5));for(const s of [-1,1]){const a=-t*2*Math.PI+(s>0?Math.PI:0),pedal=[s*13,1+12*Math.cos(a),20+12*Math.sin(a)];pipe(p,[[s*7,1,20],pedal],2.5,'grip');block(p,pedal,[12,10,2],'grip');}pipe(p,[[0,1,20],[0,18,20]],3,'metal');return p;}
function r5Rower(e,t){const drive=keyValue(t,[[0,0],[.48,1],[.56,1],[1,0]]),body=ease((drive-.2)/.8),pull=keyValue(t,[[0,0],[.16,0],[.5,1],[.57,1],[.84,0],[1,0]]),p=model([0,-8-22*drive,35],[0,.3-.55*body,1]);p.view=69;seat(p,p.hip[1],28,false,25);pipe(p,[[0,-62,17],[0,52,17]],6);block(p,[0,60,28],[40,28,53],'machine');
 for(const s of [-1,1]){leg(p,s,[s*11,23.2,20],[0,0,1],-Math.PI/2);arm(p,s,V.mix(V.add(p.shoulder,[s*9,43,-6]),V.add(p.shoulder,[s*9,10,-12]),pull),[0,-1,0]);}pipe(p,[p.j.lh,p.j.rh],3,'grip');cable(p,[0,56,55],V.mix(p.j.lh,p.j.rh,.5),'cable',false);block(p,[0,31,20],[36,7,27],'metal');return p;}
function r5Stairs(e,t){const p=r4Stairs(e,t);r5MoveSpine(p,[0,0,72],[0,0,1]);p.feet=[];p.errors=[];for(const s of [-1,1]){const u=(t+(s>0?.5:0))%1,stance=u<.5,v=stance?u/.5:(u-.5)/.5,y=stance?mix(15,-4,v):mix(-4,15,ease(v)),z=stance?mix(31.3,19.3,v):mix(19.3,31.3,ease(v))+20*Math.max(0,Math.sin(Math.PI*v))**.6;leg(p,s,[s*12,y,z],[0,1,0]);arm(p,s,[s*25,40,104],[s,-1,0]);}return p;}
function r5Stretch(e,t){const p=r4Stretch(e,t);for(const s of [-1,1])arm(p,s,[s*9,-52,13],[s,1,-.2]);return p;}
function r5Vup(e,t){const q=rep(t),a=45*q*RAD,b=(8+66*q)*RAD,p=model([0,0,6],[0,Math.cos(a),Math.sin(a)],[0,-Math.sin(a),Math.cos(a)]);p.view=68;mat(p);
 for(const s of [-1,1]){legFK(p,s,[0,-Math.cos(b),Math.sin(b)],[0,-Math.cos(b),Math.sin(b)]);r4ShinFoot(p,s);const f=p.feet.find(f=>f.s===s),o=socket(p,s),toe=V.add(f.ankle,V.mul(f.forward,9)),target=[s*(e.number===179?4:6),toe[1],toe[2]],delta=V.sub(target,o),weight=ease(q),initial=V.mul(p.up,46.5),direction=V.unit(V.mix(V.unit(initial),V.unit(delta),weight)),reach=mix(46.5,Math.min(46.8,V.len(delta)),weight);arm(p,s,V.add(o,V.mul(direction,reach)),[s,0,1]);}
 if(e.number===179)dumbbell(p,V.mix(p.j.lh,p.j.rh,.5));return p;}
function r5Bicycle(e,t){const phase=2*Math.PI*t,c=Math.cos(phase),q=(1+c)/2,up=V.unit([0,.94,.342]),a=-25*c*RAD,rotate=v=>V.add(V.add(V.mul(v,Math.cos(a)),V.mul(V.cross(up,v),Math.sin(a))),V.mul(up,V.dot(up,v)*(1-Math.cos(a)))),p=model([0,0,6],up,rotate([0,-up[2],up[1]]),rotate([1,0,0]));p.view=90;mat(p);
 for(const s of [-1,1]){const flex=s<0?q:1-q,th=(15+110*flex)*RAD,shin=(3+17*flex)*RAD;legFK(p,s,[0,-Math.cos(th),Math.sin(th)],[0,-Math.cos(shin),Math.sin(shin)]);r4ShinFoot(p,s);}
 for(const s of [-1,1]){const active=s>0?q:1-q,o=socket(p,s),k=p.j[s>0?'lk':'rk'],aim=V.unit(V.sub(k,o)),out=V.unit(V.add(V.mul(p.right,s),V.mul(p.up,-.3))),upper=V.unit(V.mix(out,aim,ease(active))),el=V.add(o,V.mul(upper,24)),handHint=V.add(p.head,V.mul(p.right,s*10));armFK(p,s,upper,V.sub(handHint,el));}return p;}
function r5Heel(e,t){const p=supine(7),bend=18*wave(t)*RAD;mat(p);articulatedCrunch(p,1.1);const rotate=v=>rotZ(v,-bend);p.spine=p.spine.map(rotate);p.shoulder=p.spine.at(-1);p.head=rotate(p.head);p.up=rotate(p.up);p.forward=rotate(p.forward);p.right=rotate(p.right);bentSupineLegs(p,14,-20);p.view=135;
 for(const s of [-1,1]){const reach=.5+.5*s*wave(t),o=socket(p,s),target=V.mix(V.add(o,[s*3,-39,-5]),[s*17,-15,5],reach),d=V.sub(target,o);arm(p,s,V.add(o,V.mul(V.unit(d),Math.min(46.8,V.len(d)))),[s,-1,.2]);}return p;}
function r5Tbar(e,t){const q=rep(t),p=model([0,-9,56+3*q],[0,.86-.08*q,.51+.115*q]);p.view=135;plantedLegs(p,19);const anchor=[0,-65,3],h=[0,24+7*q,29+24*q],axis=V.unit(V.sub(h,anchor)),tip=V.add(h,V.mul(axis,17));for(const s of [-1,1])arm(p,s,V.add(h,[s*8,0,0]),[s,-1,0]);pipe(p,[anchor,tip],3.5);pipe(p,[p.j.lh,p.j.rh],3,'grip');shape(p,'cylinder',{center:V.add(h,V.mul(axis,11)),axis,radius:14,length:6,color:'weight'});block(p,anchor,[23,15,6],'metal');return p;}
function r5StraightPulldown(e,t){const q=rep(t),p=model([0,0,61],[0,.12,.993]);p.view=90;plantedLegs(p,12);armFK(p,-1,[-.2,0,-1],[0,.2,-1]);const a=(105-98*q)*RAD;armFK(p,1,[0,Math.sin(a),-Math.cos(a)],[0,Math.sin(a),-Math.cos(a)]);const origin=[13,80,145];station(p,origin);cable(p,origin,p.j.rh);return p;}
const R5MOTIONS={15:r5Pulldown,18:r5CableRow,19:r5FacePull,22:r5Preacher,24:r5Shrug,26:r5FrontSquat,29:r5Hack,30:r5Bulgarian,32:r5Step,34:r5HingeBar,35:r5HingeBar,36:r5Bridge,37:r5Bridge,38:r5HingeBar,42:r5SidePlank,44:r5Rollout,45:r5CableCrunch,78:r5BandSquat,80:r5Arnold,88:r5Sprint,89:r5HighKnees,162:r5Bike,164:(e,t)=>cardio(e,1-t),165:r5Rower,166:r5Stairs,174:r5Stretch,178:r5Vup,179:r5Vup,183:r5Bicycle,185:r5Heel,192:r5Tbar,193:r5StraightPulldown};
function r5Finish(p,e,t){const n=e.number;
 if(n===1)p.view=120;
 if(n===5){const mat=p.objects.find(o=>o.color==='mat');mat.center[1]=20;mat.size[1]=105;}
 if(n===6)for(const s of [-1,1])r4ShinFoot(p,s,true);
 if([8,21,23,120,132].includes(n))for(const o of p.objects)if(o.type==='dumbbell'){
  const s=V.len(V.sub(o.center,p.j.lh))<V.len(V.sub(o.center,p.j.rh))?-1:1,lower=V.sub(p.j[s<0?'lh':'rh'],p.j[s<0?'le':'re']);o.axis=n===8?[0,1,0]:n===23?V.unit(V.cross(lower,p.right)):[1,0,0];}
 if(n===33)p.objects=p.objects.filter(o=>!(o.type==='line'&&o.width===3&&o.points.some(v=>Math.abs(v[0])===22&&v[1]===27&&v[2]===30)));
 if(n===59){const f=p.feet.find(f=>f.s<0),q=rep(t),pitch=1.1*ease(q/.3),z=9*Math.sin(pitch)+4.3*Math.cos(pitch);p.feet=p.feet.filter(f=>f.s>0);leg(p,-1,[-10,-58*q,z],[0,1,0],pitch);}
 if(n===134)p.objects=p.objects.filter(o=>!(o.type==='line'&&o.width===4&&o.points.length===2&&o.points[0][0]===-7&&o.points[1][0]===7));
 if([196,197].includes(n)){for(const s of [-1,1]){const a=(8+35*(n===197?1-rep(t):rep(t)))*RAD,r=[Math.cos(a),-s*Math.sin(a),0],f=[s*Math.sin(a),Math.cos(a),0],pad=p.objects.find(o=>o.type==='box'&&o.size[0]===8&&Math.sign(o.center[0])===s);pad.basis={right:r,forward:f,up:[0,0,1]};pad.center=V.add(p.j[s<0?'lk':'rk'],V.mul(r,s*(n===197?-5:5)));}}
 if([66,199].includes(n))p.feet=p.feet.filter((f,i,all)=>all.findLastIndex(g=>g.s===f.s)===i);
 if(n===199){const a=rep(t)*Math.PI;r4Foot(p,1,[0,-Math.cos(a),Math.sin(a)],[0,Math.sin(a),Math.cos(a)]);}
 return p;
}
function r5Snatch(e,t){const hip=keyValue(t,[[0,[0,-18,37]],[.2,[0,0,60.5]],[.24,[0,0,60.5]],[.3,[0,-13,34]],[.48,[0,0,60.5]],[.59,[0,0,60.5]],[.69,[0,0,60.5]],[.8,[0,-8,50]],[1,[0,-18,37]]]),a=keyValue(t,[[0,58],[.2,0],[.24,0],[.3,10],[.48,0],[.69,0],[.8,25],[1,58]])*RAD,p=model(hip,[0,Math.sin(a),Math.cos(a)]);p.view=55;plantedLegs(p,17);
 const offset=keyValue(t,[[0,-40],[.2,-40.5],[.24,-34],[.3,40.5],[.48,40.5],[.59,40.5],[.69,-40.5],[.8,-37],[1,-40]]),z=p.shoulder[2]+offset;let front=7;
 for(const s of [-1,1]){const joints=[socket(p,s,false),p.j[s<0?'lk':'rk'],p.j[s<0?'la':'ra']];for(let i=1;i<joints.length;i++){const a=joints[i-1],b=joints[i],q=clamp((z-a[2])/(b[2]-a[2]||1)),point=V.mix(a,b,q),weight=1-ease((Math.abs(point[2]-z)-5)/7);front=Math.max(front,mix(7,point[1]+7,weight));}}
 for(let i=0;i<=30;i++){const point=V.mix(p.hip,p.shoulder,i/30),weight=1-ease((Math.abs(point[2]-z)-7)/8);front=Math.max(front,mix(7,point[1]+13,weight));}
 const hw=1-ease((Math.abs(z-p.head[2])-14)/10);front=Math.max(front,mix(7,p.head[1]+14,hw));const c=[0,mix(front,3,ease((offset-32)/8)),z];for(const s of [-1,1])arm(p,s,V.add(c,[s*32,0,0]),[s,0,0]);bar(p,c,[1,0,0],48);return p;}
function r5SlamBody(t,landingY){const pickup=keyValue(t,[[0,0],[.36,0],[.58,1],[.7,.65],[1,0]]),hinge=keyValue(t,[[0,0],[.29,1],[.58,1],[1,0]]),height=60-26.5*pickup,angle=58*hinge*RAD,hipY=mix(-10*hinge,landingY-36*Math.sin(58*RAD),pickup),p=model([0,hipY,height],[0,Math.sin(angle),Math.cos(angle)]);p.view=65;plantedLegs(p,17);return p;}
function r5Slam(e,t){const release=.25,impact=.38,pickup=.58;
 // Solve the release point once from the throw, then reuse that exact landing for pickup.
 const throwPose=r5SlamBody(release,0),releaseAngle=Math.PI*(1-ease(release/.29)),releaseReach=46.2,start=V.add(throwPose.shoulder,[0,releaseReach*Math.sin(releaseAngle),-releaseReach*Math.cos(releaseAngle)]),landing=[0,start[1]+4,8],p=r5SlamBody(t,landing[1]);
 let held;
 if(t<pickup){const a=Math.PI*(1-ease(Math.min(t,.29)/.29)),h=V.add(p.shoulder,[0,46.2*Math.sin(a),-46.2*Math.cos(a)]);for(const s of [-1,1])arm(p,s,V.add(h,[s*6,0,0]),[s,0,0]);held=V.mix(p.j.lh,p.j.rh,.5);}
 else{const q=ease((t-pickup)/(1-pickup)),a=Math.PI*q,reach=mix(r5SlamBody(pickup,landing[1]).shoulder[2]-8,46.2,q),h=V.add(p.shoulder,[0,reach*Math.sin(a),-reach*Math.cos(a)]);for(const s of [-1,1])arm(p,s,V.add(h,[s*6,0,0]),[s,0,0]);held=V.mix(p.j.lh,p.j.rh,.5);}
 let ball=held;if(t>=release&&t<impact){const q=(t-release)/(impact-release),v=-12;ball=[0,mix(start[1],landing[1],q),start[2]+v*q+(8-start[2]-v)*q*q];}else if(t>=impact&&t<pickup)ball=landing;
 if(t>=.43&&t<pickup){const q=ease((t-.43)/(pickup-.43)),desired=V.mix(held,landing,q);for(const s of [-1,1]){const o=socket(p,s),d=V.sub(V.add(desired,[s*6,0,0]),o);arm(p,s,V.add(o,V.mul(V.unit(d),Math.min(46.8,V.len(d)))),[s,0,0]);}}
 shape(p,'ball',{center:ball,radius:8});return p;}
R5MOTIONS[55]=r5Snatch;R5MOTIONS[90]=r5Slam;
function r5Elliptical(e,t){const phase=2*Math.PI*t,p=model([0,0,58+Math.cos(phase*2)]);p.view=63;block(p,[0,8,-1],[60,90,4],'machine');for(const s of [-1,1]){const a=phase+(s>0?Math.PI:0),y=22*Math.sin(a),end=[s*13,y,11-4*Math.cos(a)-.18*y];leg(p,s,end,[0,1,0]);block(p,V.add(end,[0,2,-5.8]),[18,27,3],'metal');const handle=[s*24,25-14*Math.sin(a),88];arm(p,s,handle,[s,0,-1]);pipe(p,[[s*24,24,8],handle,[s*24,handle[1],112]],3);}block(p,[0,32,24],[15,25,42],'machine');return p;}
R5MOTIONS[164]=r5Elliptical;

for(const key of Object.keys(MOTIONS)){const previous=MOTIONS[key];MOTIONS[key]=(e,t)=>r5Finish(R5MOTIONS[e.number]?r4Finish(R5MOTIONS[e.number](e,t),e,t):previous(e,t),e,t);}

// Revision06: corrections corroborated by independent photographic/artifact passes.
const R6_PREVIOUS={...MOTIONS};
function r6LegFrontAt(p,z,clearance){let front=6;for(const s of [-1,1]){const points=[socket(p,s,false),p.j[s<0?'lk':'rk'],p.j[s<0?'la':'ra']];for(let i=1;i<points.length;i++){const a=points[i-1],b=points[i],u=clamp((z-a[2])/(b[2]-a[2]||1)),v=V.mix(a,b,u),w=1-ease((Math.abs(v[2]-z)-4)/8);front=Math.max(front,mix(6,v[1]+clearance,w));}}return front;}
function r6SafeBarY(p,z,base){let front=base;const radius=5.7;for(const side of [-1,1]){const joints=[socket(p,side,false),p.j[side<0?'lk':'rk'],p.j[side<0?'la':'ra']];for(let i=1;i<joints.length;i++)for(let j=0;j<=100;j++){const point=V.mix(joints[i-1],joints[i],j/100),dz=Math.abs(point[2]-z);if(dz<radius)front=Math.max(front,point[1]+Math.sqrt(radius*radius-dz*dz)+.3);else if(dz<radius+4)front=Math.max(front,mix(base,point[1]+.3,1-ease((dz-radius)/4)));}}return front;}
function r6Clean(e,t){const p=olympic(e,t),barObject=p.objects.find(o=>o.type==='bar');barObject.center[1]=r6SafeBarY(p,barObject.center[2],barObject.center[1]);for(const s of [-1,1])arm(p,s,V.add(barObject.center,[s*20,0,0]),[s,.3,-.2]);return p;}
function r6InvertedRow(e,t){const q=rep(t),legProjection=Math.sqrt(58**2-3**2),total=legProjection+36,ankle=[0,-55,4],angle=Math.asin((mix(38,53,q)-4)/total),up=[0,Math.cos(angle),Math.sin(angle)],hip=V.add(ankle,V.mul(up,legProjection)),p=model(hip,up,[0,0,1]);p.view=65;
 for(const s of [-1,1]){leg(p,s,V.add(ankle,[s*9,0,0]),[0,0,1],0,true,[0,-1,0]);arm(p,s,[s*19,31,75],[s,-.2,-1]);rail(p,s*42,31,78);}pipe(p,[[-42,31,75],[42,31,75]],4,'grip');return p;}
function r6KettlebellDeadlift(e,t){const p=hinge(e,t);p.objects=p.objects.filter(o=>o.type!=='kettlebell');let drop=45.9,y=6;for(let i=0;i<6;i++){const bellZ=p.shoulder[2]-drop-11;y=r6LegFrontAt(p,bellZ,11.6);const dy=y-p.shoulder[1];drop=Math.sqrt(Math.max(1,46.8**2-9**2-dy**2));}const center=[0,y,p.shoulder[2]-drop];for(const s of [-1,1])arm(p,s,V.add(center,[s*4,0,0]),[s,0,0]);kb(p,V.mix(p.j.lh,p.j.rh,.5));return p;}
function r6Clamshell(e,t){const p=R6_PREVIOUS[e.motion](e,t);arm(p,-1,[0,51,4],[1,0,0]);return p;}
function r6BarbellCurl(e,t){const q=rep(t),p=model();p.view=30;plantedLegs(p);for(const s of [-1,1]){const a=(16+120*q)*RAD;armFK(p,s,[s*.05,.09,-.9947],[0,Math.sin(a),-Math.cos(a)]);}loads(p,e);p.grip='supinated';return p;}
function r6ReverseCrunch(e,t){const g=ease(rep(t)),hip=[0,4*g,6+10*g],shoulder=[0,36,6],delta=V.sub(shoulder,hip),distance=V.len(delta),center=Math.atan2(delta[2],delta[1]),spread=Math.acos(clamp((distance/12-1)/2,-1,1)),p=model(hip);let at=hip;const points=[at];for(const a of [center-spread,center,center+spread]){at=V.add(at,[0,12*Math.cos(a),12*Math.sin(a)]);points.push(at);}setSpine(p,points);p.forward=[0,-p.up[2],p.up[1]];p.head=V.add(p.shoulder,V.add(V.mul(p.up,15),V.mul(p.forward,3)));p.view=68;mat(p);
 for(const s of [-1,1]){const a=(72+30*g)*RAD;legFK(p,s,[0,-Math.cos(a),Math.sin(a)],[0,-1,0]);r4ShinFoot(p,s);armFK(p,s,[s*.348,-.929,-.125],[s*.35,-.937,0]);}return p;}
const R6_MODELS={54:r6Clean,61:r6InvertedRow,96:r6KettlebellDeadlift,118:r6Clamshell,139:r6BarbellCurl,182:r6ReverseCrunch};
function r6Finish(p,e){if(e.number===176)for(const o of p.objects)if(o.type==='roller'){o.type='cylinder';o.color='pad';}return p;}
for(const key of Object.keys(MOTIONS)){const before=MOTIONS[key];MOTIONS[key]=(e,t)=>r6Finish((R6_MODELS[e.number]||before)(e,t),e);}
function r6BoxJump(e,t){
 if(t<.62){const p=jump(e,t),forward=ease((t-.22)/.21),shift=-14*(1-forward),move=v=>V.add(v,[0,shift,.3]);p.hip=move(p.hip);p.spine=p.spine.map(move);p.shoulder=p.spine.at(-1);p.head=move(p.head);for(const key of Object.keys(p.j))p.j[key]=move(p.j[key]);for(const f of p.feet)f.ankle=p.j[f.s<0?'la':'ra'];p.contacts=[];return p;}
 const leftPhase=clamp((t-.62)/.165),rightPhase=clamp((t-.785)/.165),left=mix(8,-38,ease(leftPhase)),right=mix(8,-38,ease(rightPhase)),extent=Math.abs(left-right)/46,reload=.55*ease((t-.95)/.05),height=25*(1-ease((leftPhase-.6)/.4)),load=.15*extent+reload,hip=[0,(left+right)/2-14*load,61.3+height-30*load],a=24*load*RAD,p=model(hip,[0,Math.sin(a),Math.cos(a)]);p.view=65;
 for(const s of [-1,1]){const u=s<0?leftPhase:rightPhase,y=s<0?left:right,z=29.3+18*Math.sin(Math.PI*u)-25*ease((u-.72)/.28);leg(p,s,[s*12,y,z],[0,1,0]);const aa=-.3*ease((t-.95)/.05);armFK(p,s,[s*.1,Math.sin(aa),-Math.cos(aa)],[s*.1,Math.sin(aa+.3),-Math.cos(aa+.3)]);}block(p,[0,8,12.5],[47,32,25],'wood');return p;
}
R6_MODELS[84]=r6BoxJump;

// Revision07: requested lift, band, and machine corrections. No shared renderer changes.
const R7L_PREVIOUS={...MOTIONS};
function r7LPrevious(e,t){return R7L_PREVIOUS[e.motion](e,t)}
function r7LSafeBody(p,z,base){let y=base;const radius=6.8;for(let i=0;i<p.spine.length-1;i++)for(let j=0;j<=80;j++){const v=V.mix(p.spine[i],p.spine[i+1],j/80),dz=Math.abs(v[2]-z);if(dz<radius)y=Math.max(y,v[1]+Math.sqrt(radius*radius-dz*dz)+.1);}return y;}
function r7LPreacher(e,t){const q=rep(t),p=model([0,-9,35]);p.view=30;seat(p,-9,28,false);plantedLegs(p,12,24);const down=V.unit([0,.72,-.694]),normal=V.unit([0,.694,.72]);block(p,[0,-5,57.85],[39,25,5],'pad',{right:[1,0,0],forward:down,up:normal});pipe(p,[[0,10,3],[0,11,57]],4);const start=Math.atan2(down[1],-down[2]);for(const s of [-1,1]){const a=start+(10+112*q)*RAD;armFK(p,s,down,[0,Math.sin(a),-Math.cos(a)]);dumbbell(p,p.j[s<0?'lh':'rh'],[1,0,0]);}return p;}
function r7LDeadlift(e,t){const q=1-rep(t),a=(6+49*q)*RAD,p=model([0,-18*q,60.5-23*q],[0,Math.sin(a),Math.cos(a)]);p.view=65;plantedLegs(p,12);const y=18.4,z=p.shoulder[2]-Math.sqrt(46.8**2-7**2-(y-p.shoulder[1])**2),c=[0,y,z];for(const s of [-1,1])arm(p,s,V.add(c,[s*20,0,0]),[s,.15,-1]);bar(p,c);return p;}
function r7LCrunch(e,t){const p=r7LPrevious(e,t);p.objects=p.objects.filter(o=>!(o.type==='line'&&o.color==='rope'));const front=V.add(p.head,V.mul(p.forward,14));for(const s of [-1,1])arm(p,s,V.add(front,V.mul(p.right,s*12)),V.add(V.mul(p.right,s),V.mul(p.up,-.5)));const fork=V.add(front,V.mul(p.up,16));for(const o of p.objects)if(o.type==='line'&&o.color==='cable'&&V.len(V.sub(o.points[0],[0,70,145]))<.01)o.points[o.points.length-1]=fork;for(const s of [-1,1])pipe(p,[fork,p.j[s<0?'lh':'rh']],1.3,'rope');return p;}
function r7LCalf(e,t){const p=calfRaise(e,t);p.objects=[];for(const s of [-1,1]){const z=p.shoulder[2]+4;rail(p,s*32,-15,130);block(p,[s*13,0,z],[12,19,7],'pad');pipe(p,[[s*32,-15,z+2],[s*13,-12,z+2],[s*13,0,z+2]],4);arm(p,s,[s*24,9,p.shoulder[2]-14],[s,0,-1]);pipe(p,[[s*13,9,z],p.j[s<0?'lh':'rh']],3,'grip');}return p;}
function r7LClean(e,t){const p=r7LPrevious(e,t),o=p.objects.find(o=>o.type==='bar'),rack=ease((o.center[2]-p.shoulder[2]+12)/13);o.center=V.mix(o.center,V.add(p.shoulder,[0,9,1]),rack);o.center[1]=r7LSafeBody(p,o.center[2],o.center[1]);for(const s of [-1,1])arm(p,s,V.add(o.center,[s*20,0,0]),[0,1,.1]);return p;}
function r7LSnatch(e,t){if(t<=.59){const p=r7LPrevious(e,t),o=p.objects.find(o=>o.type==='bar');o.center[1]=r7LSafeBody(p,o.center[2],r6SafeBarY(p,o.center[2],o.center[1]));for(const s of [-1,1])arm(p,s,V.add(o.center,[s*32,0,0]),[s,0,0]);return p;}const q=ease((t-.59)/.41),p=model([0,-18*q,60.5-23.5*q],[0,Math.sin(58*q*RAD),Math.cos(58*q*RAD)]);p.view=55;plantedLegs(p,17);const z=p.shoulder[2]+mix(40.5,-40,q),body=r6SafeBarY(p,z,3),headWeight=1-ease((Math.abs(z-p.head[2])-14)/10),y=Math.max(body,mix(7,p.head[1]+14,headWeight)),endY=r7LPrevious(e,0).objects.find(o=>o.type==='bar').center[1],c=[0,r7LSafeBody(p,z,Math.max(body,mix(mix(y,3,ease((mix(40.5,-40,q)-32)/8)),endY,ease((q-.7)/.3)))),z];for(const s of [-1,1])arm(p,s,V.add(c,[s*32,0,0]),[s,0,0]);bar(p,c,[1,0,0],48);return p;}
function r7LThruster(e,t){const p=r7LPrevious(e,t),barObject=p.objects.find(o=>o.type==='bar');for(const s of [-1,1])arm(p,s,V.add(barObject.center,[s*20,0,0]),[0,.2,-1]);return p;}
function r7LInverted(e,t){const q=rep(t),legProjection=Math.sqrt(58**2-3**2),total=legProjection+36,ankle=[0,-55,4],angle=Math.asin((mix(29.2,53,q)-4)/total),up=[0,Math.cos(angle),Math.sin(angle)],hip=V.add(ankle,V.mul(up,legProjection)),p=model(hip,up,[0,0,1]);p.view=65;for(const s of [-1,1]){leg(p,s,V.add(ankle,[s*9,0,0]),[0,0,1],0,true,[0,-1,0]);arm(p,s,[s*19,31,75],[s,-.2,-1]);rail(p,s*42,31,78);}pipe(p,[[-42,31,75],[42,31,75]],4,'grip');return p;}
function r7LNordic(e,t){const q=rep(t),a=78*q*RAD,p=model([0,29*Math.sin(a),4.3+29*Math.cos(a)],[0,Math.sin(a),Math.cos(a)]);p.view=70;mat(p);for(const s of [-1,1]){const knee=[s*6,0,4.3],end=[s*6,-29,4.3];p.j[s<0?'lk':'rk']=knee;p.j[s<0?'la':'ra']=end;foot(p,s,end,0,[0,-1,0]);block(p,V.add(end,[0,0,5]),[12,12,9],'pad');p.contacts.push({kind:'knee',point:knee,height:4.3});arm(p,s,V.add(p.shoulder,[s*15,22,mix(-25,4.5-p.shoulder[2],q)]),[s,0,-1]);}pipe(p,[[-23,-29,2],[23,-29,2]],5);return p;}
function r7LBandChest(e,t){const q=rep(t),p=model();p.view=60;plantedLegs(p,14);for(const s of [-1,1]){arm(p,s,[s*24,12+29*q,p.shoulder[2]-5],[s,0,-1]);cable(p,[s*48,-49,91],p.j[s<0?'lh':'rh'],'band');}return p;}
function r7LPress(e,t){const n=e.number,q=rep(t),machine=n===128,p=model(machine?[0,0,36]:[0,0,61]);p.view=25;if(machine){seat(p,0,28);for(const s of [-1,1])leg(p,s,[s*13,30,4],[0,1,0],0,true);}else plantedLegs(p);for(const s of [-1,1]){const span=mix(30,27,q),target=[s*span,mix(10,5,q),p.shoulder[2]+mix(2,Math.sqrt(46.5**2-14**2-5**2),q)];arm(p,s,target,[s,0,-.4]);const h=p.j[s<0?'lh':'rh'];if(n===70)pipe(p,[[s*11,0,1],[s*30,5,3],h],1.3,'band');else if(machine){rail(p,s*41,-21,131);const pivot=[s*41,-21,114];pipe(p,[pivot,V.add(h,[0,-5,0]),h],3);shape(p,'handle',{center:h});shape(p,'cylinder',{center:pivot,axis:[1,0,0],radius:5,length:5,color:'machine'});}else dumbbell(p,h,[1,0,0]);}return p;}
function r7LArnold(e,t){const q=rep(t),p=model();p.view=30;plantedLegs(p);for(const s of [-1,1]){const o=socket(p,s),bottom=V.add(o,[-s*3,18,1]),top=V.add(o,[s*13,4,44]),target=V.mix(bottom,top,q);arm(p,s,target,[s*.3,.4,-1]);const a=(1-q)*Math.PI/2;dumbbell(p,p.j[s<0?'lh':'rh'],[Math.cos(a),s*Math.sin(a),0]);}return p;}
function r7LBandRow(e,t){const p=row(e,t);p.objects=p.objects.filter(o=>!(o.type==='line'&&o.color==='band'));for(const s of [-1,1])cable(p,[s*5,57,7],p.j[s<0?'lh':'rh'],'band');return p;}
function r7LBandLat(e,t){const q=rep(t),p=model([0,0,35],[0,-.2*q,1]);p.view=135;bench(p,[0,-40,28],[0,17,28],32);for(const s of [-1,1]){leg(p,s,[s*12,32,4],[0,1,0],0,true);arm(p,s,[s*25,14,mix(114,71,q)],[s,.1,-1]);}const origin=[0,58,146];station(p,origin);pipe(p,[V.add(p.j.lh,[-9,0,2]),p.j.lh,p.j.rh,V.add(p.j.rh,[9,0,2])],3,'grip');cable(p,origin,V.mix(p.j.lh,p.j.rh,.5),'band',false);block(p,[0,22,40],[36,10,5],'pad');return r4Finish(p,e,t);}
function r7LPullApart(e,t){const q=rep(t),p=model();p.view=22;plantedLegs(p);for(const s of [-1,1])arm(p,s,[s*mix(15,55,q),18,94],[0,-1,-.1]);cable(p,p.j.lh,p.j.rh,'band',false);return p;}
function r7LWeightedPushdown(e,t){const p=pushdown({...e,number:10},t);return r4Finish(p,{...e,number:10},t);}
function r7LBandGoodMorning(e,t){const p=hinge(e,t);p.objects=p.objects.filter(o=>!(o.type==='line'&&o.color==='band'));for(const s of [-1,1]){const h=V.add(p.shoulder,[s*23,-5,0]);arm(p,s,h,[s,0,-1]);pipe(p,[[s*14,0,1],[s*23,0,2],h],1.3,'band');}return p;}
function r7LBandSquat(e,t){const p=r7LPrevious(e,t);p.objects=p.objects.filter(o=>!(o.type==='line'&&o.color==='band')&&o.type!=='handle');for(const s of [-1,1]){const old=p.j[s<0?'lh':'rh'];arm(p,s,[s*28,old[1],old[2]],[s,0,-1]);cable(p,[s*22,0,1.5],p.j[s<0?'lh':'rh'],'band');}return p;}
function r7LRDL(e,t){const q=rep(t),p=hinge(e,t);p.objects=p.objects.filter(o=>o.type!=='dumbbell');for(const s of [-1,1]){arm(p,s,[s*24,p.shoulder[1]+5,p.shoulder[2]-44],[s,0,-1]);const a=(1-q)*Math.PI/2;dumbbell(p,p.j[s<0?'lh':'rh'],[Math.cos(a),Math.sin(a),0]);}return p;}
function r7LPullover(e,t){const q=rep(t),a=80*q*RAD,p=supine(39);p.view=65;bench(p);bentSupineLegs(p);const center=V.add(p.shoulder,[0,44*Math.sin(a),44*Math.cos(a)]);for(const s of [-1,1])arm(p,s,V.add(center,[s*4,0,0]),[s,0,0]);dumbbell(p,V.mix(p.j.lh,p.j.rh,.5),[0,1,0]);return p;}
function r7LCarry(e,t){const p=r7LPrevious(e,t);p.objects=p.objects.filter(o=>o.type!=='dumbbell');for(const s of [-1,1]){armFK(p,s,[s*.3,0,-1],[s*.12,0,-1]);if(e.number===91||s<0)dumbbell(p,p.j[s<0?'lh':'rh'],[0,1,0]);}return p;}
function r7LTriceps(e,t){const q=rep(t),a=(5+105*q)*RAD,p=model();p.view=60;plantedLegs(p);const reach=Math.sqrt(23**2-9**2);for(const s of [-1,1]){const el=V.add(socket(p,s),[0,0,24]);p.j[s<0?'le':'re']=el;p.j[s<0?'lh':'rh']=V.add(el,[-s*9,-reach*Math.sin(a),reach*Math.cos(a)]);}dumbbell(p,V.mix(p.j.lh,p.j.rh,.5),[1,0,0]);return p;}
function r7LBandTriceps(e,t){const p=tricepsExtension(e,t);p.objects=p.objects.filter(o=>!(o.type==='line'&&o.color==='band')&&o.type!=='handle');const h=V.mix(p.j.lh,p.j.rh,.5),fork=V.add(h,[0,-8,0]),origin=[0,-55,90];cable(p,origin,fork,'band',false);for(const s of [-1,1])cable(p,fork,p.j[s<0?'lh':'rh'],'band',true);return r4Finish(p,e,t);}
function r7LPecDeck(e,t){const p=chestFly(e,t);p.objects=p.objects.filter(o=>!(o.type==='box'&&o.size[0]===8)&&!(o.type==='line'&&o.points.some(v=>Math.abs(v[0])===35&&v[1]===-10&&v[2]===85)));for(const s of [-1,1]){const h=p.j[s<0?'lh':'rh'];rail(p,s*40,-20,122);pipe(p,[[s*40,-20,118],[s*35,-10,118],[s*35,h[1],118],V.add(h,[0,0,7])],3);block(p,h,[8,5,12],'pad');}return p;}
function r7LSeatedRow(e,t){const q=rep(t),p=model([0,-10,35],[0,.1,.995]);p.view=60;seat(p,-10,28,false);for(const s of [-1,1]){leg(p,s,[s*12,35.5,11],[0,1,0],-Math.PI/2);arm(p,s,[s*13,p.shoulder[1]+mix(44,8,q),58],[s*.1,-1,0]);}block(p,[0,42,11],[38,5,19],'metal');pipe(p,[p.j.lh,p.j.rh],3,'grip');const origin=[0,70,61];station(p,origin);cable(p,origin,V.mix(p.j.lh,p.j.rh,.5),'cable',false);pipe(p,[[0,70,3],[0,-10,3]],5);return r4Finish(p,e,t);}
function r7LReversePec(e,t){const q=rep(t),p=model([0,0,35],[0,.1,.995]);p.view=35;seat(p,0,28,false);plantedLegs(p,12,28);block(p,[0,10,54],[26,5,35],'pad');for(const s of [-1,1]){const a=80*q*RAD,dir=V.add(V.mul(p.forward,Math.cos(a)),V.mul(p.right,s*Math.sin(a)));armFK(p,s,dir,dir);const h=p.j[s<0?'lh':'rh'];rail(p,s*72,-20,119);pipe(p,[[s*72,-20,119],V.add(h,[0,0,14]),V.add(h,[0,0,6])],3);pipe(p,[V.add(h,[0,0,-6]),V.add(h,[0,0,6])],3,'grip');}return p;}
function r7LFrontSquat(e,t){const p=squatPose(rep(t)*1.08);p.view=36;for(const s of [-1,1]){arm(p,s,V.add(p.shoulder,[s*24,11,3]),[s,0,-1]);dumbbell(p,p.j[s<0?'lh':'rh'],[0,1,0]);}return p;}
const R7L_MODELS={22:r7LPreacher,34:r7LDeadlift,45:r7LCrunch,48:r7LCalf,54:r7LClean,55:r7LSnatch,56:r7LThruster,61:r7LInverted,64:r7LNordic,69:r7LBandChest,70:r7LPress,71:r7LBandRow,72:r7LBandLat,73:r7LPullApart,75:r7LWeightedPushdown,77:r7LBandGoodMorning,78:r7LBandSquat,79:r7LPress,80:r7LArnold,82:r7LRDL,83:r7LPullover,91:r7LCarry,92:r7LCarry,119:r7LTriceps,122:r7LBandTriceps,128:r7LPress,130:r7LPecDeck,133:r7LSeatedRow,137:r7LReversePec,142:r7LFrontSquat};
function r7LFinish(p,e,t){const n=e.number;if(n===21)for(const o of p.objects)if(o.type==='dumbbell'){const s=V.len(V.sub(o.center,p.j.lh))<V.len(V.sub(o.center,p.j.rh))?-1:1;o.axis=V.unit(V.sub(p.j[s<0?'lh':'rh'],p.j[s<0?'le':'re']));}if([97,120,132].includes(n))for(const o of p.objects)if(o.type==='dumbbell')o.axis=[0,1,0];if(n===40)p.objects=p.objects.filter(o=>!(o.type==='line'&&o.width===3));if(n===129)p.objects=p.objects.filter(o=>!(o.type==='line'&&o.width===4&&o.points.every(v=>v[0]===0&&v[1]===-20)));if(n===135){p.objects=p.objects.filter(o=>!(o.type==='line'&&o.color==='band'));const a=[43,15,144],end=p.j.ra;pipe(p,[V.add(a,[-2,0,0]),V.add(end,[-3,0,-2]),V.add(end,[3,0,-2]),V.add(a,[2,0,0])],1.3,'band');}return p;}
const R7L_IDS=new Set([21,22,34,40,45,48,54,55,56,61,64,69,70,71,72,73,75,77,78,79,80,82,83,91,92,97,119,120,122,128,129,130,132,133,135,137,142]);
for(const key of Object.keys(MOTIONS)){const before=MOTIONS[key];MOTIONS[key]=(e,t)=>R7L_IDS.has(e.number)?r7LFinish((R7L_MODELS[e.number]||before)(e,t),e,t):before(e,t);}

// Revision07: reviewed floor exercises and stretches. No shared renderer changes.
const R7F_PREVIOUS={...MOTIONS};
function r7FBase(e,t){return R7F_PREVIOUS[e.motion](e,t)}
function r7FHeadFloor(p){const hu=p.headUp||p.up,hr=p.headRight||p.right,hf=V.unit(V.sub(p.forward,V.mul(hu,V.dot(p.forward,hu)))),bottom=p.head[2]-9*Math.abs(hu[2])-7*Math.abs(hf[2])-8.5*Math.abs(hr[2]);if(bottom<.7)p.head[2]+=.7-bottom;}
function r7FPike(e,t){const q=rep(t),a=(46+12*q)*RAD,p=model([0,-12,58],[0,Math.cos(a),-Math.sin(a)],[0,-Math.sin(a),-Math.cos(a)]);p.view=75;mat(p);for(const s of [-1,1]){leg(p,s,[s*6,-39,9.98],[0,1,0],1.08);arm(p,s,[s*18,42,3.5],[s*.2,-1,0]);}r7FHeadFloor(p);return p;}
function r7FMountain(e,t){const p=plankBase();p.feet=[];p.contacts=[];for(const s of [-1,1]){const q=rep((t+(s>0?.5:0))%1),end=V.mix([s*6,-62.71,9.82],[s*15,3,14],q);leg(p,s,end,[s*.35,1,.15],mix(1.08,.4,q));}return p;}
function r7FIncline(e,t){const q=rep(t),ankle=[0,-80,9.98],shoulderZ=mix(86,52.5,q),a=Math.asin((shoulderZ-ankle[2])/94),up=[0,Math.cos(a),Math.sin(a)],p=model(V.add(ankle,V.mul(up,58)),up,[0,0,-1]);p.view=75;mat(p);p.objects[0].center[1]=-5;p.objects[0].size[1]=110;block(p,[0,-10,20],[55,30,40],'pad');for(const s of [-1,1]){legFK(p,s,V.mul(up,-1),V.mul(up,-1),1.08);arm(p,s,[s*18,-10,43],[s*.2,-1,0]);}return p;}
function r7FFold(e,t){const p=model([0,0,62],[0,.694,-.72],[0,-.72,-.694]);p.view=72;for(const s of [-1,1]){legFK(p,s,[0,0,-1],[0,0,-1]);arm(p,s,[s*9,8,4.5],[s,0,1]);}r7FHeadFloor(p);return p;}
function r7FCat(e,t){const b=wave(t),p=model([0,-10,33]);p.view=68;mat(p);const points=[p.hip];let at=p.hip;for(const ang of [20+24*b,20,20-24*b]){at=V.add(at,[0,12*Math.cos(ang*RAD),12*Math.sin(ang*RAD)]);points.push(at);}p.forward=[0,.342,-.94];setSpine(p,points);p.headUp=V.unit([0,1,-.35*b]);p.head=V.add(p.shoulder,V.mul(p.headUp,15));for(const s of [-1,1]){legFK(p,s,[0,0,-1],[0,-1,0],0,[0,-1,0]);r4Foot(p,s,[0,-1,0],[0,0,-1]);arm(p,s,[s*13,31,3.5],[s*.4,0,-1]);}return p;}
function r7FChild(e,t){const p=model([0,-24,18.8],[0,.985,-.174],[0,0,-1]);p.view=74;mat(p);for(const s of [-1,1]){legFK(p,s,[s*.28,.82,-.5],[0,-1,0],0,[0,-1,0]);r4Foot(p,s,[0,-1,0],[0,0,-1]);arm(p,s,[s*13,57,3.8],[s*.3,0,1]);}p.headUp=[0,1,0];p.head=[0,26,11];r7FHeadFloor(p);return p;}
function r7FWide(e,t){const p=model([0,0,52],[0,.745,-.667],[0,-.667,-.745]);p.view=32;for(const s of [-1,1]){leg(p,s,[s*30,0,4.3],[s*.4,1,0],0,true);armFK(p,s,[s*.12,.03,-.9923],[0,1,0]);}r7FHeadFloor(p);return p;}
function r7FShoulder(e,t){const p=model();p.view=30;plantedLegs(p);armFK(p,1,[-.96,.28,0],[-.96,.28,0]);arm(p,-1,[-3,16,97],[-1,1,-1]);return p;}
function r7FTriceps(e,t){const p=model();p.view=30;plantedLegs(p);p.headUp=[0,.6,.8];p.headRight=[1,0,0];p.head=V.add(p.shoulder,[0,9,12]);armFK(p,1,[0,-.15,.989],[.05,-.2,-.978]);arm(p,-1,V.add(p.j.re,[0,-3,0]),[-1,-4,2]);return p;}
function r7FFigure(e,t){const p=supine(6);p.view=135;mat(p);legFK(p,-1,[0,-.3,.954],[0,-1,0],0,[0,-1,0]);r4ShinFoot(p,-1);leg(p,1,[-7,-7,42],[1,0,1],0,false,[0,-1,0]);r4Foot(p,1,[0,-1,0],[1,0,0]);for(const s of [-1,1])arm(p,s,[-6+s*5,-4,23],[s,-1,1]);return p;}
function r7FDoor(e,t){const q=rep(t),p=model([0,-8+5*q,57],[0,.08+.06*q,1]);p.view=50;leg(p,-1,[-10,-19,4.3],[0,1,0],0,true);leg(p,1,[10,15,4.3],[0,1,0],0,true);arm(p,1,[35,12,118],[1,.5,-.2]);armFK(p,-1,[-.08,0,-1],[0,0,-1]);for(const s of [-1,1])rail(p,s*35,12,145);pipe(p,[[-35,12,145],[35,12,145]],4);return p;}
function r7FCalfStretch(e,t){const q=rep(t),p=model([0,-10+2*q,57],[0,.25+.13*q,1]);p.view=70;leg(p,-1,[-9,-27,4.3],[0,1,0],0,true);leg(p,1,[9,12,4.3],[0,1,0],0,true);for(const s of [-1,1])arm(p,s,[s*17,39,89],[0,-1,0]);block(p,[0,41,68],[65,4,136],'wall');return p;}
function r7FThread(e,t){const p=model([0,-10,33],[0,.91,-.414],[0,-.414,-.91]);p.view=-55;mat(p);for(const s of [-1,1]){legFK(p,s,[0,0,-1],[0,-1,0],0,[0,-1,0]);r4Foot(p,s,[0,-1,0],[0,0,-1]);}arm(p,-1,[31,17,4],[0,-1,.1]);arm(p,1,[24,47,3.5],[1,1,0]);p.head=[-8,37,11];p.headUp=[0,1,0];p.headRight=[1,0,0];r7FHeadFloor(p);return p;}
function r7FTwist(e,t){const a=-82*RAD,p=supine(8),rot=v=>[v[0]*Math.cos(a)+v[2]*Math.sin(a),v[1],-v[0]*Math.sin(a)+v[2]*Math.cos(a)];p.hipRight=rot([1,0,0]);p.view=135;mat(p);for(const s of [-1,1]){legFK(p,s,rot([0,-.7,.714]),[0,-1,0]);r4Foot(p,s,[0,-1,0],[-1,0,0]);arm(p,s,[s*56,36,4.3],[s,0,1]);}return p;}
function r7FStance(e,t){const p=r7FBase(e,t);r4ShinFoot(p,1,true);return p;}
function r7FKneePush(e,t){const p=r7FBase(e,t);for(const s of [-1,1])r4ShinFoot(p,s,true);return p;}
function r7FClosePush(e,t){const p=r7FBase(e,t),m=p.objects.find(o=>o.type==='box'&&o.color==='mat');m.center[1]=20;m.size[1]=105;return p;}
function r7FWallSit(e,t){const p=model([0,0,35.3]);p.view=65;for(const s of [-1,1]){leg(p,s,[s*12,29,4.3],[0,1,0],0,true);arm(p,s,[s*11,24,40],[s,0,-1]);}block(p,[0,-9,65],[65,4,130],'wall');return p;}
function r7FHandsHead(e,t){const p=r7FBase(e,t);for(const s of [-1,1])arm(p,s,V.add(p.head,V.add(V.mul(p.right,s*12),V.mul(p.forward,2))),V.add(V.mul(p.right,s),V.mul(p.up,-.3)));return p;}
function r7FHipThrust(e,t){const p=r7FBase(e,t),c=V.add(p.hip,[0,0,10]);for(const s of [-1,1])arm(p,s,V.add(c,[s*7,0,0]),[s,0,0]);return p;}
function r7FCrunch(e,t){const p=supine();mat(p);articulatedCrunch(p,rep(t));bentSupineLegs(p,12,-29);for(const s of [-1,1]){const h=V.add(p.head,V.add(V.mul(p.right,s*13),V.mul(p.forward,-1))),pole=V.add(V.mul(p.right,s),V.add(V.mul(p.up,-.35),V.mul(p.forward,.2)));arm(p,s,h,pole);}return p;}
function r7FCurlup(e,t){const p=supine();mat(p);articulatedCrunch(p,.65*rep(t));bentSupineLegs(p,12,-29);for(const s of [-1,1])arm(p,s,[s*9,-3,4.3],[s,0,0]);return p;}
function r7FLegRaise(e,t){const p=r7FBase(e,t);for(const s of [-1,1])arm(p,s,[s*17,-1,4.3],[s,0,0]);return p;}
function r7FNeck(e,t){const p=r7FBase(e,t);arm(p,1,V.add(p.head,V.add(V.mul(p.headRight,12),V.mul(p.headUp,6))),[1,1,0]);return p;}
function r7FProneFoot(e,t){const p=r7FBase(e,t);for(const s of (e.number===173?[-1]:[-1,1]))r4Foot(p,s,[0,-1,0],[0,0,-1]);return p;}
function r7FHamstring(e,t){const p=model([0,0,9],[0,-.58,.815],[0,-.815,-.58]);p.view=68;mat(p);for(const s of [-1,1]){legFK(p,s,[0,-1,0],[0,-1,0]);r4ShinFoot(p,s);arm(p,s,[s*6,-60.5,15],[s,0,1]);}return p;}
function r7FHeel(e,t){const p=r7FBase(e,t);for(const s of [-1,1]){const reach=.5+.5*s*wave(t),o=socket(p,s),target=V.mix([s*30,-1,7],[s*23,-14,6],reach),d=V.sub(target,o);arm(p,s,V.add(o,V.mul(V.unit(d),Math.min(46.8,V.len(d)))),[s,0,1]);}return p;}
function r7FTap(e,t){const p=plankBase();for(const s of [-1,1]){const u=s<0?t*2:(t-.5)*2,q=u>=0&&u<=1?rep(u):0,start=[s*18,25,3],end=V.add(socket(p,-s),V.mul(p.forward,7)),h=V.add(V.mix(start,end,q),V.mul(p.forward,12*Math.sin(Math.PI*q)));arm(p,s,h,V.add(V.mul(p.right,s*.2),V.mul(p.forward,2)));}return p;}
const R7F_MODELS={60:r7FPike,68:r7FMountain,95:r7FIncline,98:r7FFold,103:r7FCat,105:r7FChild,107:r7FWide,108:r7FShoulder,109:r7FTriceps,110:r7FFigure,111:r7FDoor,112:r7FCalfStretch,113:r7FThread,114:r7FTwist,115:r7FStance,123:r7FKneePush,125:r7FClosePush,141:r7FWallSit,150:r7FHandsHead,152:r7FHipThrust,156:r7FCrunch,157:r7FCurlup,158:r7FLegRaise,170:r7FNeck,171:r7FProneFoot,173:r7FProneFoot,174:r7FHamstring,185:r7FHeel,187:r7FTap};
function r7FFinish(p,e){if([107,111,112,141].includes(e.number))for(const c of p.contacts)if(c.kind==='foot')c.point=V.add(c.point,[0,0,-.3]);return p;}
for(const key of Object.keys(MOTIONS)){const previous=MOTIONS[key];MOTIONS[key]=(e,t)=>R7F_MODELS[e.number]?r7FFinish(R7F_MODELS[e.number](e,t),e):previous(e,t);}

// Revision07: dynamic, carry, cable, and foot corrections from the user's complete review.
const R7D_PREVIOUS={...MOTIONS};
function r7DBase(e,t){return R7D_PREVIOUS[e.motion](e,t);}
function r7DTower(p,origin,end,lift){const x=origin[0],y=origin[1]+12,top=Math.max(150,origin[2]+8),stack=[x,y,29+lift];for(const s of [-1,1])pipe(p,[[x+s*10,y,4],[x+s*10,y,top]],2.4);block(p,[x,y,3],[35,32,5],'metal');block(p,stack,[16,12,40],'machine');for(let z=-15;z<=15;z+=6)pipe(p,[[x-8,y-6.1,stack[2]+z],[x+8,y-6.1,stack[2]+z]],.6,'grip');const upper=[x,y,top-4];for(const [a,b]of [[V.add(stack,[0,0,20]),upper],[upper,origin],[origin,end]])cable(p,a,b,'cable',false);shape(p,'pulley',{center:upper});shape(p,'pulley',{center:origin});}
function r7DGetup(e,t){const p=r7DBase(e,t),u=t<=.6?t/.6:(1-t)/.4,ends=[p.j.la,p.j.ra],knees=[p.j.lk,p.j.rk];p.feet=[];for(const side of [-1,1]){const i=side<0?0:1,end=[...ends[i]];end[2]=Math.max(4.3,end[2]);leg(p,side,end,V.sub(knees[i],socket(p,side,false)));const ankle=p.j[side<0?'la':'ra'],k=p.j[side<0?'lk':'rk'],blend=ease((ankle[2]-16)/8),normal=V.unit(V.mix([0,0,1],V.unit(V.sub(k,ankle)),blend)),angle=Math.PI*(1-ease((u-.44)/.24));r4Foot(p,side,[.35*Math.sin(angle),Math.cos(angle),0],normal);}return p;}
function r7DBound(e,t){const w=2*Math.PI*t,land=Math.cos(w)**2,hip=[-20*Math.cos(w),-7*land,43+21*(1-land)],p=model(hip,[0,.13+.18*land,1]);p.view=30;p.center=[0,0,0];const left=keyValue(t,[[0,[-25,0,4.3]],[.25,[-5,-16,27]],[.5,[32,-22,15]],[.75,[-5,-16,27]],[1,[-25,0,4.3]]]),right=keyValue(t,[[0,[-32,-22,15]],[.25,[5,-16,27]],[.5,[25,0,4.3]],[.75,[5,-16,27]],[1,[-32,-22,15]]]);for(const s of [-1,1]){leg(p,s,s<0?left:right,[s*.2,1,0]);const a=.45*s*Math.cos(w);armFK(p,s,[s*.18,Math.sin(a),-Math.cos(a)],[s*.1,.95,-.31]);}return p;}
function r7DRope(e,t){const hop=7*rep(t+.5),p=model([0,0,57+hop]);p.view=30;for(const s of [-1,1]){leg(p,s,[s*9,0,4.3+hop],[0,1,0]);arm(p,s,[s*35,5,59+hop*.3],[s,0,-1]);}const h=V.mix(p.j.lh,p.j.rh,.5),a=2*Math.PI*t,pts=[];for(let i=0;i<=48;i++){const u=i/48*Math.PI,r=64*Math.sin(u);pts.push([-35*Math.cos(u),h[1]+r*Math.sin(a),Math.max(1.5,h[2]-r*Math.cos(a))]);}pipe(p,pts,1.3,'rope');for(const s of [-1,1])pipe(p,[p.j[s<0?'lh':'rh'],V.add(p.j[s<0?'lh':'rh'],[0,3,-4])],3,'grip');return p;}
function r7DMarch(e,t){const high=e.number===89,p=model([0,0,62.3]);p.view=65;for(const s of [-1,1]){const u=(t+(s>0?.5:0))%1,q=u<.5?Math.sin(2*Math.PI*u)**2:0,a=(high?105:62)*q*RAD;legFK(p,s,[0,Math.sin(a),-Math.cos(a)],[0,0,-1]);const f=p.feet.find(f=>f.s===s);f.forward=[0,1,0];f.up=[0,0,1];f.right=[1,0,0];const swing=(high?.45:.22)*Math.sin(2*Math.PI*u);armFK(p,s,[0,-Math.sin(swing),-Math.cos(swing)],[0,Math.cos(swing),-Math.sin(swing)]);}return p;}
function r7DSlam(e,t){const u=keyValue(t,[[0,0],[.22,.25],[.31,.38],[.48,.58],[1,1]]);return r5Slam(e,u);}
function r7DBandWalk(e,t){const rightX=keyValue(t,[[0,14],[.25,38],[.75,38],[1,14]]),leftX=keyValue(t,[[0,-14],[.25,-14],[.5,10],[.75,-14],[1,-14]]),hipX=(rightX+leftX)/2,p=model([hipX,0,49]);p.view=10;p.center=[12,0,0];for(const s of [-1,1]){const lift=s>0?(t<.25?6*Math.sin(4*Math.PI*t)**2:t>.75?6*Math.sin(4*Math.PI*(t-.75))**2:0):t>.25&&t<.75?6*Math.sin(4*Math.PI*(t-.25))**2:0;leg(p,s,[s>0?rightX:leftX,0,4.3+lift],[s*.1,1,0]);arm(p,s,V.add(p.shoulder,[s*4,17,-15]),[s,0,-1]);}const l=V.mix(p.j.lk,p.j.la,.2),rr=V.mix(p.j.rk,p.j.ra,.2);pipe(p,[V.add(l,[0,3,0]),V.add(rr,[0,3,0])],4,'band');pipe(p,[V.add(l,[0,-3,0]),V.add(rr,[0,-3,0])],3,'band');return p;}
function r7DSplit(e,t){const p=r7DBase(e,t);for(const s of [-1,1])arm(p,s,V.add(p.shoulder,[s*2,23,-15]),[s,0,-.3]);return p;}
function r7DSideLunge(e,t){const q=rep(t),p=model([18*q,-6*q,57-22*q],[0,.18,.984]);p.view=15;for(const s of [-1,1]){leg(p,s,[s*30,0,4.3],[s*.2,1,0],0,true);arm(p,s,V.add(p.shoulder,[s*3,20,-15]),[s,0,-1]);}return p;}
function r7DPullThrough(e,t){const q=rep(t),a=65*q*RAD,p=model([0,-18*q,59-3*q],[0,Math.sin(a),Math.cos(a)]);p.view=67;for(const s of [-1,1])leg(p,s,[s*22,0,4.3],[s*.4,1,0]);const y=mix(14,-6,q),drop=Math.sqrt(46.5**2-(y-p.shoulder[1])**2-9**2),h=[0,y,p.shoulder[2]-drop];for(const s of [-1,1])arm(p,s,V.add(h,[s*4,0,0]),[s,0,-1]);const fork=V.add(V.mix(p.j.lh,p.j.rh,.5),[0,-5,0]),origin=[0,-82,7];for(const s of [-1,1])pipe(p,[fork,p.j[s<0?'lh':'rh']],1.3,e.number===153?'band':'rope');if(e.number===153){rail(p,0,-82,120);cable(p,origin,fork,'band',false);}else{const min=V.len(V.sub([0,-11,71.214-Math.sqrt(46.5**2-20**2-9**2)],origin));r7DTower(p,origin,fork,Math.max(0,V.len(V.sub(fork,origin))-min));}return p;}
function r7DCalf(e,t){const q=rep(t),a=.47*q,z=9*Math.sin(a)+4.3*Math.cos(a),y=9-9*Math.cos(a)+4.3*Math.sin(a),p=model([0,0,61+z-4.3]);p.view=65;leg(p,1,[11,y,z],[0,1,0],a,true);legFK(p,-1,[0,-.1,-1],[0,-.8,.6]);const normal=V.unit(V.sub(p.j.lk,p.j.la));r4Foot(p,-1,V.cross([-1,0,0],normal),normal);hangArms(p);if(e.number===155){armFK(p,1,[.24,0,-1],[.12,0,-1]);dumbbell(p,p.j.rh,[0,1,0]);}return p;}
function r7DRecumbent(e,t){return cardio(e,1-t);}
function r7DElliptical(e,t){return r5Elliptical(e,1-t);}
function r7DRower(e,t){const p=r5Rower(e,t);for(const s of [-1,1])arm(p,s,p.j[s<0?'lh':'rh'],[s,-.15,0]);return p;}
function r7DStairs(e,t){const p=r5Stairs(e,t);for(const s of [-1,1]){const a=.12*Math.sin(2*Math.PI*t+(s>0?Math.PI:0));armFK(p,s,[s*.1,Math.sin(a),-Math.cos(a)],[s*.05,Math.sin(a+.15),-Math.cos(a+.15)]);}return p;}
function r7DWrist(e,t){const p=model();p.view=45;plantedLegs(p);for(const s of [-1,1]){armFK(p,s,[s*.05,.82,-.57],[0,1,0]);const h=p.j[s<0?'lh':'rh'],a=2*Math.PI*t,d=V.unit([s*.32*Math.cos(a),1,.32*Math.sin(a)]);shape(p,'hand',{center:h,direction:d});p.j[s<0?'lfingertip':'rfingertip']=V.add(h,V.mul(d,6));}return p;}
function r7DLegSwing(e,t){const angle=40*wave(t)*RAD,p=model([0,0,62.3]);p.view=63;leg(p,-1,[-6,0,4.3],[0,1,0]);const end=[6,58*Math.sin(angle),62.3-58*Math.cos(angle)],bottom=4.3*Math.cos(angle)+(angle<0?9:3)*Math.abs(Math.sin(angle));end[2]=Math.max(end[2],bottom);leg(p,1,end,[0,1,0]);r4Foot(p,1,[0,Math.cos(angle),Math.sin(angle)],[0,-Math.sin(angle),Math.cos(angle)]);arm(p,-1,[-22,28,90],[-1,0,-1]);armFK(p,1,[.1,0,-1],[.1,0,-1]);pipe(p,[[-25,30,0],[-25,30,107]],4);return p;}
function r7DWoodchop(e,t){const a=-40*wave(t)*RAD,p=model();p.right=rotZ([1,0,0],a);p.forward=rotZ([0,1,0],a);p.view=30;plantedLegs(p,17);const h=[16*wave(t),24,85-15*wave(t)];for(const s of [-1,1])arm(p,s,V.add(h,V.mul(p.right,s*4)),V.add(V.mul(p.right,s),[0,0,-.4]));const origin=[-65,35,133],end=V.mix(p.j.lh,p.j.rh,.5),min=V.len(V.sub([-16,24,100],origin));r7DTower(p,origin,end,Math.max(0,V.len(V.sub(end,origin))-min));return p;}
function r7DRow(e,t){const q=rep(t),p=model([0,-10,35],[0,.1,.995]);p.view=60;seat(p,-10,28,false);for(const s of [-1,1])leg(p,s,[s*12,35.5,11],[0,1,0],-Math.PI/2);block(p,[0,42,11],[38,5,19],'metal');armFK(p,-1,[-.12,0,-1],[-.06,.2,-1]);arm(p,1,V.mix(V.add(p.shoulder,[13,45,-2]),V.add(p.shoulder,[13,7,-10]),q),[1,-.2,0]);shape(p,'handle',{center:p.j.rh});const origin=[13,83,75],rest=V.add(p.shoulder,[13,45,-2]);r7DTower(p,origin,p.j.rh,Math.max(0,V.len(V.sub(p.j.rh,origin))-V.len(V.sub(rest,origin))));return p;}
function r7DKickback(e,t){const q=rep(t),p=model([0,0,62.2],[0,.25,.968]);p.view=67;leg(p,-1,[-7,0,4.3],[0,1,0],0,true);const a=(7+73*q)*RAD,b=(10+70*q)*RAD;legFK(p,1,[0,-Math.sin(a),-Math.cos(a)],[0,-Math.sin(b),-Math.cos(b)]);r4ShinFoot(p,1);for(const s of [-1,1])arm(p,s,[s*18,38,84],[s,0,-1]);pipe(p,[[-23,40,0],[-23,40,89],[23,40,89],[23,40,0]],4);const origin=[20,82,6],rest=[6,-29*Math.sin(7*RAD)-29*Math.sin(10*RAD),62.2-29*Math.cos(7*RAD)-29*Math.cos(10*RAD)];r7DTower(p,origin,p.j.ra,Math.max(0,V.len(V.sub(p.j.ra,origin))-V.len(V.sub(rest,origin))));shape(p,'cuff',{center:p.j.ra});return p;}
function r7DDonkey(e,t){const p=quadrupedBase(),q=rep(t),a=q*Math.PI/2,b=(12+78*q)*RAD;legFK(p,1,[0,-Math.sin(a),-Math.cos(a)],[0,-Math.cos(b),Math.sin(b)]);p.feet=p.feet.filter((f,i,all)=>all.findLastIndex(g=>g.s===f.s)===i);r4Foot(p,1,[0,-Math.sin(b),-Math.cos(b)],[0,Math.cos(b),-Math.sin(b)]);p.j.la=[-6,-10-Math.sqrt(29**2-.3**2),4.3];p.feet.find(f=>f.s<0).ankle=p.j.la;return p;}
const R7D_MODELS={57:r7DGetup,86:r7DBound,87:r7DRope,89:r7DMarch,90:r7DSlam,117:r7DBandWalk,145:r7DSplit,146:r7DSideLunge,153:r7DPullThrough,154:r7DCalf,155:r7DCalf,163:r7DRecumbent,164:r7DElliptical,165:r7DRower,166:r7DStairs,168:r7DMarch,175:r7DWrist,177:r7DLegSwing,188:r7DWoodchop,190:r7DRow,195:r7DKickback,198:r7DPullThrough,199:r7DDonkey};
for(const key of Object.keys(MOTIONS)){const previous=MOTIONS[key];MOTIONS[key]=(e,t)=>{const p=(R7D_MODELS[e.number]||previous)(e,t);if([146,154,155,195].includes(e.number))for(const c of p.contacts)if(c.kind==='foot'){const f=p.feet.find(f=>f.support&&Math.abs(f.ankle[0]-c.point[0])<15);if(f)c.point=V.add(f.ankle,V.add(V.mul(f.forward,9),V.mul(f.up,-4.3)));}return p;};}


// Revision08: precise grip, movement-plane, range and apparatus refinements from the completed review.
const R8L_PREVIOUS={...MOTIONS};
function r8LBase(e,t){return R8L_PREVIOUS[e.motion](e,t)}
function r8LHand(p,wrist,center){pipe(p,[wrist,center],3.5,'skin');}
function r8LHammer(e,t){const p=r8LBase(e,t);for(const o of p.objects)if(o.type==='dumbbell'){const s=V.len(V.sub(o.center,p.j.lh))<V.len(V.sub(o.center,p.j.rh))?-1:1,h=p.j[s<0?'lh':'rh'];o.axis=[0,0,1];o.center=V.add(h,[0,8.2,0]);r8LHand(p,h,o.center);}return p;}
function r8LCrunch(e,t){const q=rep(t),p=model([0,-15,33]);p.view=65;mat(p);let at=p.hip;const points=[at];for(const a of [10+40*q,10+60*q,10+90*q]){at=V.add(at,[0,12*Math.sin(a*RAD),12*Math.cos(a*RAD)]);points.push(at);}setSpine(p,points);p.forward=[0,p.up[2],-p.up[1]];p.head=V.add(p.shoulder,V.add(V.mul(p.up,15),V.mul(p.forward,3)));const front=V.add(p.head,V.mul(p.forward,14));for(const s of [-1,1])arm(p,s,V.add(front,[s*12,0,0]),[s,0,-.2]);const origin=[0,70,145],fork=V.add(front,V.mul(p.up,16));station(p,origin);cable(p,origin,fork,'cable',false);for(const s of [-1,1])pipe(p,[fork,p.j[s<0?'lh':'rh']],1.3,'rope');for(const s of [-1,1])legFK(p,s,[0,0,-1],[0,-1,0],0,[0,-1,0]);return r4Finish(p,e,t);}
function r8LClean(e,t){const p=r8LBase(e,t),o=p.objects.find(x=>x.type==='bar'),rack=ease((o.center[2]-p.shoulder[2]+20)/20);for(const s of [-1,1])arm(p,s,V.add(o.center,[s*20,0,0]),V.mix([s*.35,-1,-.1],[s*.35,1,.1],rack));return p;}
function r8LSnatch(e,t){if(t<=.56)return r8LBase(e,t);const u=clamp((t-.56)/.36),q=ease(u),p=model([0,-18*q,60.5-23.5*q],[0,Math.sin(58*q*RAD),Math.cos(58*q*RAD)]);p.view=55;plantedLegs(p,17);const initial=r8LBase(e,0).objects.find(o=>o.type==='bar').center,top=r8LBase(e,.56).objects.find(o=>o.type==='bar').center,z=mix(top[2],initial[2],q),y=keyValue(u,[[0,top[1]],[.18,24],[.78,24],[1,initial[1]]]),c=[0,y,z];for(const s of [-1,1])arm(p,s,V.add(c,[s*32,0,0]),[s,0,0]);bar(p,c,[1,0,0],48);return p;}
function r8LThruster(e,t){const q=rep(t),depth=1-q,tilt=24*depth*RAD,p=model([0,-14*depth,60.6-34.6*depth],[0,Math.sin(tilt),Math.cos(tilt)]);p.view=38;for(const s of [-1,1])leg(p,s,[s*18,0,4],[s*.6,1,0],0,true);const press=ease((q-.5)/.5),height=mix(-3,46.2,press),c=V.add(p.shoulder,[0,mix(15,3,ease((height-28)/15)),height]);for(const s of [-1,1])arm(p,s,V.add(c,[s*20,0,0]),[0,.2,-1]);bar(p,c);return p;}
function r8LBandPress(e,t){const p=r8LBase(e,t);p.objects=p.objects.filter(o=>!(o.type==='line'&&o.color==='band'));const a=[-15.5,4,1],b=[15.5,4,1];pipe(p,[a,b],1.3,'band');for(const s of [-1,1])cable(p,s<0?a:b,p.j[s<0?'lh':'rh'],'band',false);return p;}
function r8LBandRow(e,t){const q=rep(t),p=model([0,-10,54],[0,.9,.436]);p.view=60;plantedLegs(p);for(const s of [-1,1]){const origin=[s*13,67,15],near=[s*13,14,56],far=V.mix(origin,near,.45);arm(p,s,V.mix(far,near,q),[s*.2,-1,0]);cable(p,origin,p.j[s<0?'lh':'rh'],'band',false);}pipe(p,[[-23,67,2],[23,67,2]],4);pipe(p,[[0,67,2],[0,67,95]],3);pipe(p,[[-15,67,15],[15,67,15]],3,'metal');return p;}
function r8LBandLat(e,t){const q=rep(t),p=model([0,0,35],[0,-.12*q,1]);p.view=135;bench(p,[0,-40,28],[0,17,28],32);for(const s of [-1,1]){leg(p,s,[s*12,32,4],[0,1,0],0,true);arm(p,s,[s*20,mix(27.85,6,q),mix(103.1,72,q)],[s*.25,0,-1]);}const origin=[0,58,146];station(p,origin);pipe(p,[V.add(p.j.lh,[-8,0,0]),p.j.lh,p.j.rh,V.add(p.j.rh,[8,0,0])],3,'grip');cable(p,origin,V.mix(p.j.lh,p.j.rh,.5),'band',false);block(p,[0,22,40],[36,10,5],'pad');return r4Finish(p,e,t);}
function r8LPushdown(e,t){const q=rep(t),p=model();p.view=60;plantedLegs(p);for(const s of [-1,1]){const a=mix(-6,8,q)*RAD,b=(100-90*q)*RAD;armFK(p,s,[s*.07,Math.sin(a),-Math.cos(a)],[0,Math.sin(b),-Math.cos(b)]);}const origin=[0,40,145];station(p,origin);cable(p,origin,V.mix(p.j.lh,p.j.rh,.5),'cable',false);pipe(p,[p.j.lh,p.j.rh],3,'grip');return r4Finish(p,{...e,number:10},t);}
function r8LGoodMorning(e,t){const p=hinge(e,t);p.objects=p.objects.filter(o=>!(o.type==='line'&&o.color==='band'));for(const s of [-1,1]){armFK(p,s,[s*.28,0,-1],[s*.08,0,1]);cable(p,[s*15.5,4,1],p.j[s<0?'lh':'rh'],'band',false);}return p;}
function r8LPress(e,t){const q=rep(t),p=model();p.view=25;plantedLegs(p);for(const s of [-1,1]){const x=mix(30,9.5,q),y=mix(10,3,q),z=p.shoulder[2]+mix(2,46.3,q);arm(p,s,[s*x,y,z],[s,0,-.4]);dumbbell(p,p.j[s<0?'lh':'rh'],[1,0,0]);}return p;}
function r8LArnold(e,t){const p=r8LBase(e,t),q=rep(t);for(const o of p.objects)if(o.type==='dumbbell'){const s=V.len(V.sub(o.center,p.j.lh))<V.len(V.sub(o.center,p.j.rh))?-1:1,a=(1-q)*Math.PI,axis=[Math.cos(a),s*Math.sin(a),0];o.axis=axis;const thumb=V.add(o.center,V.mul(axis,2.4));pipe(p,[thumb,V.add(thumb,[0,0,2.8])],1.4,'skin');}return p;}
function r8LRDL(e,t){const p=r8LBase(e,t),q=rep(t),a=15*(1-q)*RAD;for(const o of p.objects)if(o.type==='dumbbell'){const s=V.len(V.sub(o.center,p.j.lh))<V.len(V.sub(o.center,p.j.rh))?-1:1;o.axis=[s*Math.sin(a),Math.cos(a),0];}return p;}
function r8LPullover(e,t){const p=r8LBase(e,t),a=80*rep(t)*RAD;for(const o of p.objects)if(o.type==='dumbbell')o.axis=[0,Math.cos(a),-Math.sin(a)];return p;}
function r8LFly(e,t){const q=rep(t),p=supine(39);p.view=38;bench(p);bentSupineLegs(p);for(const s of [-1,1]){const a=70*(1-q)*RAD,b=48*(1-q)*RAD;armFK(p,s,[s*Math.sin(a),0,Math.cos(a)],[s*Math.sin(b),0,Math.cos(b)]);dumbbell(p,p.j[s<0?'lh':'rh'],[0,1,0]);}return p;}
function r8LTriceps(e,t){const p=r8LBase(e,t),q=rep(t),c=V.add(V.mix(p.j.lh,p.j.rh,.5),[0,-8.5,0]),a=30*(1-q)*RAD;p.objects=p.objects.filter(o=>o.type!=='dumbbell');dumbbell(p,c,[0,Math.sin(a),Math.cos(a)]);for(const s of [-1,1])r8LHand(p,p.j[s<0?'lh':'rh'],V.add(c,[s*2.5,0,0]));return p;}
function r8LKickback(e,t){const p=r8LBase(e,t);for(const o of p.objects)if(o.type==='dumbbell'){const s=V.len(V.sub(o.center,p.j.lh))<V.len(V.sub(o.center,p.j.rh))?-1:1,lower=V.sub(p.j[s<0?'lh':'rh'],p.j[s<0?'le':'re']);o.axis=V.unit(V.cross([1,0,0],lower));}return p;}
function r8LBandTriceps(e,t){const p=r8LBase(e,t);p.objects=p.objects.filter(o=>!(o.type==='line'&&o.color==='band')&&o.type!=='handle');const mid=V.mix(p.j.lh,p.j.rh,.5),origin=[0,-55,90],fork=V.add(mid,V.mul(V.unit(V.sub(origin,mid)),9));cable(p,origin,fork,'band',false);for(const s of [-1,1])cable(p,fork,p.j[s<0?'lh':'rh'],'band',true);return p;}
function r8LAssist(e,t){const q=rep(t),span=27,handY=15,bodyY=-14,hang=144-Math.sqrt(46.9**2-14**2-(handY-bodyY)**2),p=model([0,bodyY,mix(hang-36,104,q)]);p.view=40;p.scale=1.25;p.grip='pronated';for(const side of [-1,1]){arm(p,side,[side*span,handY,144],[side,0,-.1]);legFK(p,side,[0,-.15,-1],[0,-.35,-1],.15);rail(p,side*50,handY,150);}pipe(p,[[-50,handY,144],[50,handY,144]],4,'grip');const origin=[0,15,144],ankle=V.mix(p.j.la,p.j.ra,.5),end=V.add(ankle,[0,9,-5.8]);pipe(p,[V.add(origin,[-2,0,0]),V.add(end,[-3,0,0]),V.add(end,[3,0,0]),V.add(origin,[2,0,0])],1.3,'band');return p;}
function r8LReversePec(e,t){const q=rep(t),p=model([0,0,35],[0,.1,.995]);p.view=35;seat(p,0,28,false);plantedLegs(p,12,28);block(p,[0,10,54],[26,5,35],'pad');pipe(p,[[0,-24,3],[0,-24,121],[0,4,121]],5);for(const s of [-1,1]){const a=80*q*RAD,pivot=[s*7,4,115],end=[s*(7+40*Math.sin(a)),4+40*Math.cos(a),115],h=[end[0],end[1],70.8];pipe(p,[[0,4,121],pivot,end,h],3);shape(p,'cylinder',{center:pivot,axis:[0,0,1],radius:4,length:5,color:'machine'});arm(p,s,h,[s*.3,-.2,-1]);shape(p,'handle',{center:h});}return p;}
const R8L_MODELS={21:r8LHammer,45:r8LCrunch,54:r8LClean,55:r8LSnatch,56:r8LThruster,70:r8LBandPress,71:r8LBandRow,72:r8LBandLat,75:r8LPushdown,77:r8LGoodMorning,79:r8LPress,80:r8LArnold,82:r8LRDL,83:r8LPullover,97:r8LFly,119:r8LTriceps,120:r8LKickback,122:r8LBandTriceps,135:r8LAssist,137:r8LReversePec};
function r8LFinish(p,e){if(e.number===40){const r=V.mix(p.j.la,p.j.ra,.5);for(const o of p.objects)if(o.type==='box'&&o.size[0]===42)o.center=V.add(r,[0,0,8.7]);}return p;}
const R8L_IDS=new Set([21,40,45,48,54,55,56,70,71,72,75,77,79,80,82,83,97,119,120,122,135,137]);
for(const key of Object.keys(MOTIONS)){const previous=MOTIONS[key];MOTIONS[key]=(e,t)=>R8L_IDS.has(e.number)?r8LFinish((R8L_MODELS[e.number]||previous)(e,t),e):previous(e,t);}

// Revision08: floor/stretch refinements from the completed user review.
const R8F_PREVIOUS={...MOTIONS};
function r8FBase(e,t){return R8F_PREVIOUS[e.motion](e,t);}
function r8FPike(e,t){const q=rep(t),a=(28+34*q)*RAD,b=(15+15*q)*RAD,ankle=[0,-39,10.15],hip=V.add(ankle,[0,58*Math.sin(b),58*Math.cos(b)]),p=model(hip,[0,Math.cos(a),-Math.sin(a)],[0,-Math.sin(a),-Math.cos(a)]);p.view=75;mat(p);for(const s of [-1,1]){leg(p,s,[s*6,-39,10.15],[0,1,0],1.08);arm(p,s,[s*18,12,3.5],[s*.5,-1,0]);}return p;}
function r8FIncline(e,t){const q=rep(t),ankle=[0,-100,10.15],sz=mix(84,52.5,q),a=Math.asin((sz-ankle[2])/94),up=[0,Math.cos(a),Math.sin(a)],p=model(V.add(ankle,V.mul(up,58)),up,[0,0,-1]);p.view=75;mat(p);p.objects[0].center[1]=-17;p.objects[0].size[1]=110;block(p,[0,-10,20],[55,30,40],'pad');for(const s of [-1,1]){legFK(p,s,V.mul(up,-1),V.mul(up,-1),1.08);arm(p,s,[s*18,-23,43],[s*.5,-1,.1]);}return p;}
function r8FCat(e,t){const b=wave(t),angles=[20+24*b,20,20-24*b].map(x=>x*RAD),p=model([0,-10,33]);p.view=68;mat(p);const points=[p.hip];let at=p.hip;for(const a of angles){at=V.add(at,[0,12*Math.cos(a),12*Math.sin(a)]);points.push(at);}setSpine(p,points);const first=angles[0],last=angles[2];p.up=[0,Math.cos(first),Math.sin(first)];p.forward=[0,Math.sin(first),-Math.cos(first)];p.headUp=[0,Math.cos(last),Math.sin(last)];p.head=V.add(p.shoulder,V.mul(p.headUp,15));for(const s of [-1,1]){legFK(p,s,[0,0,-1],[0,-1,0],0,[0,-1,0]);r4Foot(p,s,[0,-1,0],[0,0,-1]);arm(p,s,[s*13,31,3.5],[s*.4,0,-1]);}return p;}
function r8FChild(e,t){const p=r8FBase(e,t);for(const s of [-1,1])armFK(p,s,[0,1,-.19],[0,1,-.19]);return p;}
function r8FFigure(e,t){const p=supine(6);p.view=135;mat(p);legFK(p,-1,[0,-.6,.8],[0,-1,0],0,[0,-1,0]);r4ShinFoot(p,-1);leg(p,1,[-7,-12,38],[1,-.3,.2]);r4Foot(p,1,[0,0,1],[1,0,0]);for(const s of [-1,1])arm(p,s,[-3+s*5,-4,22],[s,-1,1]);return p;}
function r8FDoor(e,t){const q=rep(t),p=model([0,-8+5*q,57],[0,.04+.1*q,1]);p.view=30;leg(p,-1,[-10,-19,4.3],[0,1,0]);leg(p,1,[10,15,4.3],[0,1,0]);for(const s of [-1,1]){const o=socket(p,s),dy=3-o[1],el=[s*(13+Math.sqrt(24**2-dy**2)),3,o[2]],dx=s*36-el[0],hand=[s*36,3,el[2]+Math.sqrt(23**2-dx**2)];p.j[s<0?'le':'re']=el;p.j[s<0?'lh':'rh']=hand;rail(p,s*36,8,145);}pipe(p,[[-36,8,145],[36,8,145]],4);return p;}
function r8FCalfStretch(e,t){const q=rep(t),p=model([0,-7+4*q,57],[0,.02+.4*q,1]);p.view=70;leg(p,-1,[-9,-27,4.3],[0,1,0]);leg(p,1,[9,12,4.3],[0,1,0]);for(const s of [-1,1])arm(p,s,[s*17,39,89],[0,-1,0]);block(p,[0,41,68],[65,4,136],'wall');return p;}
function r8FThread(e,t){const p=r7FThread(e,t),o=socket(p,-1),el=V.add(o,V.mul(V.unit(V.sub([-9,4,4],o)),24));p.j.le=el;p.j.lh=V.add(el,[23,0,0]);return p;}
function r8FTwist(e,t){const q=rep(t),a=-82*q*RAD,p=supine(8),rot=v=>[v[0]*Math.cos(a)+v[2]*Math.sin(a),v[1],-v[0]*Math.sin(a)+v[2]*Math.cos(a)];p.hipRight=rot([1,0,0]);p.view=135;mat(p);for(const s of [-1,1]){legFK(p,s,rot([0,-.7,.714]),[0,-1,0]);r4Foot(p,s,rot([0,0,1]),[0,1,0]);arm(p,s,[s*56,36,4.3],[s,0,1]);}return p;}
function r8FNeck(e,t){const q=rep(t),a=21*q*RAD,p=model();p.view=16;plantedLegs(p);p.headUp=[Math.sin(a),0,Math.cos(a)];p.headRight=[Math.cos(a),0,-Math.sin(a)];p.head=V.add(p.shoulder,V.mul(p.headUp,15));armFK(p,-1,[-.05,0,-1],[0,0,-1]);const start=V.add(socket(p,1),[0,0,-46.8]),end=V.add(p.head,V.add(V.mul(p.headRight,12),V.mul(p.headUp,6)));arm(p,1,V.add(V.mix(start,end,q),[5*Math.sin(Math.PI*q),0,0]),[1,1,0]);return p;}
function r8FCobra(e,t){const q=rep(t),a=(6+67.5*q)*RAD,p=model([0,0,8],[0,Math.cos(a),Math.sin(a)],[0,Math.sin(a),-Math.cos(a)]);p.view=73;mat(p);for(const s of [-1,1]){legFK(p,s,[0,-.998,-.069],[0,-1,0],0,[0,-1,0]);r4Foot(p,s,[0,-1,0],[0,0,-1]);const o=socket(p,s),near=[s*15,36,3.5],dy=Math.sqrt(Math.max(0,46.999**2-(o[2]-3.5)**2-2**2)),full=[s*15,o[1]+dy,3.5];arm(p,s,V.mix(near,full,ease((q-.75)/.25)),[s,-1,0]);}const h=(6+112.5*q)*RAD;p.headUp=[0,Math.cos(h),Math.sin(h)];p.headRight=[1,0,0];p.head=V.add(p.shoulder,V.add(V.mul(p.headUp,15),[0,3*Math.sin(h),-3*Math.cos(h)]));return p;}
function r8FPigeon(e,t){const p=r8FBase(e,t);p.feet=p.feet.filter(f=>f.s!==1);leg(p,1,[-13,19,4.3],[1,1,-.5]);r4Foot(p,1,[0,1,0],[1,0,0]);return p;}
function r8FTap(e,t){const z=10.15,upZ=(50-z)/94,up=[0,Math.sqrt(1-upZ*upZ),upZ],hip=V.add([0,-62.71412405002387,z],V.mul(up,58)),p=model(hip,up,[0,up[2],-up[1]]);p.view=75;mat(p);for(const s of [-1,1]){legFK(p,s,V.mul(up,-1),V.mul(up,-1),1.08);const u=s<0?t*2:(t-.5)*2,q=u>=0&&u<=1?rep(u):0,start=V.add(socket(p,s),[0,0,-47]),end=V.add(socket(p,-s),V.mul(p.forward,7)),h=V.add(V.mix(start,end,q),V.mul(p.forward,12*Math.sin(Math.PI*q)));if(q===0)armFK(p,s,[0,0,-1],[0,0,-1]);else arm(p,s,h,V.add(V.mul(p.right,s*.2),V.mul(p.forward,2)));}return p;}
const R8F_MODELS={60:r8FPike,95:r8FIncline,103:r8FCat,105:r8FChild,110:r8FFigure,111:r8FDoor,112:r8FCalfStretch,113:r8FThread,114:r8FTwist,170:r8FNeck,171:r8FCobra,173:r8FPigeon,187:r8FTap};
for(const key of Object.keys(MOTIONS)){const previous=MOTIONS[key];MOTIONS[key]=(e,t)=>(R8F_MODELS[e.number]||previous)(e,t);}

// Revision08: requested dynamic, cable, shoe, and hand refinements.
const R8D_PREVIOUS={...MOTIONS};
function r8DBase(e,t){return R8D_PREVIOUS[e.motion](e,t);}
function r8DGetup(e,t){const p=r8DBase(e,t);for(const s of [-1,1])r4Foot(p,s,[0,-1,0],[0,0,1]);return p;}
function r8DBound(e,t){const p=r8DBase(e,t),w=2*Math.PI*t,land=Math.cos(w)**2,old={up:p.up,forward:p.forward,right:p.right,shoulder:p.shoulder},up=[-.25*Math.cos(w)+.35*Math.sin(w),.13+.18*land,1],m=model(p.hip,up);m.right=V.unit(V.cross(m.forward,m.up));const rotate=v=>V.add(V.add(V.mul(m.right,V.dot(v,old.right)),V.mul(m.forward,V.dot(v,old.forward))),V.mul(m.up,V.dot(v,old.up)));for(const k of ['up','forward','right','spine','shoulder','head'])p[k]=m[k];for(const k of ['le','re','lh','rh'])p.j[k]=V.add(p.shoulder,rotate(V.sub(p.j[k],old.shoulder)));return p;}
function r8DSlamBody(t,landingY){const h=keyValue(t,[[0,0],[.1,.08],[.30,1],[.60,1],[1,0]]),a=78*h*RAD,p=model([0,-10*h,61-41*h],[0,Math.sin(a),Math.cos(a)]);p.view=65;p.slamLandingY=landingY;for(const side of [-1,1])leg(p,side,[side*17,0,4.3],[0,1,0]);return p;}
function r8DSlamCenter(p,t){const bottom=r8DSlamBody(.6,p.slamLandingY).shoulder,follow=p.slamLandingY-bottom[1];let target;if(t<.60){const a=Math.PI*(1-ease(t/.30)),reach=Math.min(46.3,p.shoulder[2]-8);target=V.add(p.shoulder,[0,reach*Math.sin(a)+follow*ease((t-.30)/.30),-reach*Math.cos(a)]);}else{const q=ease((t-.60)/.40),a=Math.PI*q,reach=mix(bottom[2]-8,46.3,q);target=V.add(p.shoulder,[0,reach*Math.sin(a)+follow*(1-q),-reach*Math.cos(a)]);}const delta=V.sub(target,p.shoulder);return V.add(p.shoulder,V.mul(V.unit(delta),Math.min(46.3,V.len(delta))));}
function r8DSlam(e,t){const release=.16,impact=.218,dt=impact-release,eps=1e-5,start=r8DSlamCenter(r8DSlamBody(release,0),release),left=r8DSlamCenter(r8DSlamBody(release-eps,0),release-eps),right=r8DSlamCenter(r8DSlamBody(release+eps,0),release+eps),velocity=V.mul(V.sub(right,left),1/(2*eps)),landingY=start[1]+velocity[1]*dt,landing=[0,landingY,8],p=r8DSlamBody(t,landingY),center=r8DSlamCenter(p,t);for(const side of [-1,1])arm(p,side,V.add(center,[side*6,0,0]),[side,0,0]);const held=V.mix(p.j.lh,p.j.rh,.5);let ball=held;if(t>=release&&t<impact){const u=t-release,acceleration=(8-start[2]-velocity[2]*dt)/(dt*dt);ball=[0,start[1]+velocity[1]*u,start[2]+velocity[2]*u+acceleration*u*u];}else if(t>=impact&&t<.60)ball=landing;shape(p,'ball',{center:ball,radius:8});p.j.ball=ball;return p;}
function r8DWrist(e,t){const p=model();p.view=45;plantedLegs(p);for(const s of [-1,1]){armFK(p,s,[s*.05,.82,-.57],[0,1,0]);const h=p.j[s<0?'lh':'rh'],a=2*Math.PI*t,d=V.unit([s*.22*Math.cos(a),1,.22*Math.sin(a)]),up=V.unit(V.cross([1,0,0],d)),right=V.unit(V.cross(d,up)),basis={right,forward:d,up};block(p,V.add(h,V.mul(d,3)),[4.6,5.5,2.5],'skin',basis);block(p,V.add(h,V.mul(d,6.4)),[4.1,2,2.1],'skin',basis);block(p,V.add(h,V.add(V.mul(d,2.8),V.mul(right,-s*2.7))),[1.8,3.2,2.2],'skin',basis);p.j[s<0?'lfingertip':'rfingertip']=V.add(h,V.mul(d,7.4));}return p;}
function r8DWoodchop(e,t){const q=rep(t),a=(40-80*q)*RAD,p=model();p.right=rotZ([1,0,0],a);p.forward=rotZ([0,1,0],a);p.view=30;plantedLegs(p,17);const h=V.mix([-18,25,130],[19,21,78],q);for(const s of [-1,1])arm(p,s,V.add(h,V.mul(p.right,s*4)),V.add(V.mul(p.right,s),[0,0,-.5]));const origin=[-85,55,146],end=V.mix(p.j.lh,p.j.rh,.5),rest=[-18,25,130];r7DTower(p,origin,end,Math.max(0,V.len(V.sub(end,origin))-V.len(V.sub(rest,origin))));return p;}
function r8DRow(e,t){const q=rep(t),p=model([0,-10,35],[0,.1,.995]);p.view=60;seat(p,-10,28,false);for(const s of [-1,1])leg(p,s,[s*12,35.5,11],[0,1,0],-Math.PI/2);block(p,[0,42,11],[38,5,19],'metal');armFK(p,1,[.12,0,-1],[.06,.2,-1]);const start=V.add(p.shoulder,[-17,44.5,-2]),end=V.add(p.shoulder,[-17,16.5,-24]);arm(p,-1,V.mix(start,end,q),[-.3,-1,-1]);shape(p,'handle',{center:p.j.lh});const origin=[-17,83,75];r7DTower(p,origin,p.j.lh,Math.max(0,V.len(V.sub(p.j.lh,origin))-V.len(V.sub(start,origin))));return p;}
function r8DKickback(e,t){const p=model([0,0,62.2],[0,.25,.968]);p.view=67;leg(p,-1,[-7,0,4.3],[0,1,0],0,true);const q=rep(t),a=(7+73*q)*RAD,b=(10+70*q)*RAD;legFK(p,1,[0,-Math.sin(a),-Math.cos(a)],[0,-Math.sin(b),-Math.cos(b)]);const shoePitch=b*ease((p.j.ra[2]-5.2)/12);r4Foot(p,1,[0,Math.cos(shoePitch),-Math.sin(shoePitch)],[0,Math.sin(shoePitch),Math.cos(shoePitch)]);const origin=[10,49,6],rest=[6,-29*Math.sin(7*RAD)-29*Math.sin(10*RAD),62.2-29*Math.cos(7*RAD)-29*Math.cos(10*RAD)];r7DTower(p,origin,p.j.ra,Math.max(0,V.len(V.sub(p.j.ra,origin))-V.len(V.sub(rest,origin))));for(const s of [-1,1]){const h=[s*24,39,84];arm(p,s,h,[s,0,-1]);const mount=[10+s*10,61,84];pipe(p,[[s*24,39,84],[s*26,61,84],mount],3.5,'metal');pipe(p,[[s*24,35,84],[s*24,43,84]],3,'grip');}shape(p,'cuff',{center:p.j.ra});for(const c of p.contacts)if(c.kind==='foot')c.point=V.add(p.j.la,[0,9,-4.3]);return p;}
function r8DDonkey(e,t){const p=r8DBase(e,t),k=p.j.lk,z=2,dy=Math.sqrt(29**2-(z-k[2])**2);p.j.la=[k[0],k[1]-dy,z];const f=p.feet.find(f=>f.s===-1);f.ankle=p.j.la;r4Foot(p,-1,[0,-1,0],[0,0,-1]);return p;}
const R8D_MODELS={57:r8DGetup,86:r8DBound,90:r8DSlam,175:r8DWrist,188:r8DWoodchop,190:r8DRow,195:r8DKickback,199:r8DDonkey};
for(const key of Object.keys(MOTIONS)){const before=MOTIONS[key];MOTIONS[key]=(e,t)=>(R8D_MODELS[e.number]||before)(e,t);}


// Revision09: requested lift refinements; shared renderer and unrequested poses remain unchanged.
const R9L_PREVIOUS={...MOTIONS};
function r9LBase(e,t){return R9L_PREVIOUS[e.motion](e,t)}
function r9LHammer(e,t){const p=r9LBase(e,t);p.objects=p.objects.filter(o=>!(o.type==='line'&&o.color==='skin'&&o.width===3.5));for(const o of p.objects)if(o.type==='dumbbell'){const s=V.len(V.sub(o.center,p.j.lh))<V.len(V.sub(o.center,p.j.rh))?-1:1,h=p.j[s<0?'lh':'rh'],axis=V.unit(V.sub(h,p.j[s<0?'le':'re'])),out=V.unit(V.sub([s,0,0],V.mul(axis,axis[0]*s)));o.axis=axis;o.center=V.add(h,V.mul(out,8.3));pipe(p,[h,o.center],3.5,'skin');}return p;}
function r9LCurlPad(e,t){const p=r9LBase(e,t),k=V.mix(p.j.lk,p.j.rk,.5),a=V.mix(p.j.la,p.j.ra,.5),along=V.unit(V.sub(a,k)),normal=V.unit(V.cross(along,[1,0,0]));for(const o of p.objects)if(o.type==='box'&&o.size[0]===42){o.center=V.add(V.mix(k,a,.83),V.mul(normal,8.65));o.basis={right:[1,0,0],forward:V.mul(along,-1),up:normal};}return p;}
function r9LClean(e,t){const p=r9LBase(e,t),o=p.objects.find(o=>o.type==='bar'),rack=ease((o.center[2]-p.shoulder[2]+24)/26);o.center=V.mix(o.center,V.add(p.shoulder,[0,6.5,4.5]),rack);p.head=V.add(p.head,V.mul(p.forward,-8*rack));for(const s of [-1,1])arm(p,s,V.add(o.center,[s*20,0,0]),V.mix([s*.65,-1,-.3],[s*.65,1,-.1],rack));return p;}
function r9LSnatch(e,t){const u=t<=.7?t*.8:t<=.92?.56+(t-.7)*(.36/.22):t;return r9LBase(e,u);}
function r9LThruster(e,t){const q=rep(t),depth=1-q,tilt=26*depth*RAD,p=model([0,-15*depth,60-36*depth],[0,Math.sin(tilt),Math.cos(tilt)]);p.view=38;for(const s of [-1,1])leg(p,s,[s*21,0,4.3],[s*.8,1,0]);const press=ease((q-.5)/.5),height=mix(-3,46.2,press),c=V.add(p.shoulder,[0,mix(15,3,ease((height-28)/15)),height]);for(const s of [-1,1])arm(p,s,V.add(c,[s*20,0,0]),[0,.2,-1]);bar(p,c);return p;}
function r9LBandRow(e,t){const q=rep(t),p=model([0,-10,58],[0,.45,.893]);p.view=60;plantedLegs(p);for(const s of [-1,1]){const origin=[s*13,67,70],near=[s*13,16,78],far=V.mix(origin,near,.45);arm(p,s,V.mix(far,near,q),[s*.4,-1,-.2]);cable(p,origin,p.j[s<0?'lh':'rh'],'band',false);}pipe(p,[[-23,67,2],[23,67,2]],4);pipe(p,[[0,67,2],[0,67,105]],3);pipe(p,[[-15,67,70],[15,67,70]],3,'metal');return p;}
function r9LGoodMorning(e,t){const p=hinge(e,t);p.objects=p.objects.filter(o=>!(o.type==='line'&&o.color==='band'));for(const s of [-1,1]){const h=V.add(p.shoulder,V.add(V.mul(p.right,s*9),V.add(V.mul(p.forward,9),V.mul(p.up,3))));arm(p,s,h,V.add(V.mul(p.right,s*.8),V.mul(p.up,-1)));const guide=V.add(p.shoulder,V.mul(p.right,s*22));pipe(p,[[s*16,4,1],guide,p.j[s<0?'lh':'rh']],1.3,'band');}return p;}
function r9LPress(e,t){const q=rep(t),p=model();p.view=25;plantedLegs(p);const d2=24**2+23**2-2*24*23*Math.cos(95*RAD),bottomZ=Math.sqrt(d2-23.5**2-4**2);for(const s of [-1,1]){arm(p,s,[s*mix(36.5,9.5,q),mix(4,3,q),p.shoulder[2]+mix(bottomZ,46.3,q)],[s,.1,-.4]);dumbbell(p,p.j[s<0?'lh':'rh'],[1,0,0]);}return p;}
function r9LRDL(e,t){const p=r9LBase(e,t),a=15*(1-rep(t))*RAD;for(const o of p.objects)if(o.type==='dumbbell'){const s=V.len(V.sub(o.center,p.j.lh))<V.len(V.sub(o.center,p.j.rh))?-1:1;o.axis=[Math.cos(a),s*Math.sin(a),0];}return p;}
function r9LTriceps(e,t){const p=r9LBase(e,t);p.objects=p.objects.filter(o=>!(o.type==='line'&&o.color==='skin'&&o.width===3.5));return p;}
const R9L_MODELS={21:r9LHammer,40:r9LCurlPad,54:r9LClean,55:r9LSnatch,56:r9LThruster,71:r9LBandRow,77:r9LGoodMorning,79:r9LPress,82:r9LRDL,119:r9LTriceps};
for(const key of Object.keys(MOTIONS)){const previous=MOTIONS[key];MOTIONS[key]=(e,t)=>(R9L_MODELS[e.number]||previous)(e,t);}

// Revision09: floor contact, stretch motion, and natural arm-path refinements.
const R9F_PREVIOUS={...MOTIONS};
function r9FBase(e,t){return R9F_PREVIOUS[e.motion](e,t)}
function r9FHeadMinimum(p){const u=p.headUp||p.up,r=p.headRight||p.right,f=V.unit(V.sub(p.forward,V.mul(u,V.dot(p.forward,u)))),h=p.head;return Math.min(h[2]-9*Math.abs(u[2])-7*Math.abs(f[2])-8.5*Math.abs(r[2]),h[2]+8*u[2]-2.5*Math.abs(u[2])-8*Math.abs(f[2])-9.5*Math.abs(r[2]),h[2]-6*f[2]-8.5*Math.abs(u[2])-1.7*Math.abs(f[2])-9*Math.abs(r[2]));}
function r9FCrunchPose(q,last){const p=model([0,-15,33]);let at=p.hip;const points=[at];for(const a of [10+55*q,10+90*q,10+(last-10)*q]){at=V.add(at,[0,12*Math.sin(a*RAD),12*Math.cos(a*RAD)]);points.push(at);}setSpine(p,points);p.forward=[0,p.up[2],-p.up[1]];p.head=V.add(p.shoulder,V.add(V.mul(p.up,15),V.mul(p.forward,3)));return p;}
let R9F_CRUNCH_LAST=140;{let a=135,b=145;for(let i=0;i<45;i++){const m=(a+b)/2;if(r9FHeadMinimum(r9FCrunchPose(1,m))>.04)a=m;else b=m;}R9F_CRUNCH_LAST=(a+b)/2;}
function r9FCrunch(e,t){const q=rep(t),p=r9FCrunchPose(q,R9F_CRUNCH_LAST);p.view=65;mat(p);for(const s of [-1,1]){legFK(p,s,[0,0,-1],[0,-1,0],0,[0,-1,0]);const early=V.add(p.head,V.mul(p.forward,14)),ground=[s*17,p.head[1]+15,2.9],target=V.mix([s*17,early[1],early[2]],ground,ease((q-.65)/.35));arm(p,s,target,[s,0,0]);}const mid=V.mix(p.j.lh,p.j.rh,.5),fork=[0,Math.max(mid[1]+10,p.head[1]+25),Math.max(mid[2]+18,p.head[2]+22)],origin=[0,70,145];station(p,origin);cable(p,origin,fork,'cable',false);for(const s of [-1,1])pipe(p,[fork,[s*22,fork[1],fork[2]],p.j[s<0?'lh':'rh']],1.3,'rope');return r4Finish(p,e,t);}
function r9FPike(e,t){const q=rep(t),a=(28+34*q)*RAD,b=(18+12*q)*RAD,ankle=[0,-39,10.15],hip=V.add(ankle,[0,58*Math.sin(b),58*Math.cos(b)]),p=model(hip,[0,Math.cos(a),-Math.sin(a)],[0,-Math.sin(a),-Math.cos(a)]);p.view=75;mat(p);for(const s of [-1,1]){leg(p,s,[s*6,-39,10.15],[0,1,0],1.08);arm(p,s,[s*18,20,3.5],[s*.5,-1,0]);}return p;}
function r9FFigure(e,t){const q=rep(t),p=supine(6);p.view=135;mat(p);const direction=V.unit(V.mix([0,-.6,.8],[0,-.2,.98],q));legFK(p,-1,direction,[0,-1,0],0,[0,-1,0]);r4ShinFoot(p,-1);const knee=p.j.lk;leg(p,1,V.add(knee,[-1,5.4,8.8]),[1,-.3,.2]);r4Foot(p,1,[0,0,1],[1,0,0]);const thigh=V.mix(socket(p,-1,false),knee,.5),front=V.unit([0,direction[2],-direction[1]]);for(const s of [-1,1])arm(p,s,V.add(thigh,V.add(V.mul(front,5.4),[s*4.5,0,0])),[s,-1,1]);return p;}
function r9FCalfStretch(e,t){const q=rep(t),p=model([0,-16+13*q,54.7+2.3*q],[0,.01+.41*q,1]);p.view=70;leg(p,-1,[-9,-27,4.3],[0,1,0]);leg(p,1,[9,12,4.3],[0,1,0]);for(const s of [-1,1])arm(p,s,[s*17,30.6,89],[0,-1,0]);block(p,[0,35.5,68],[65,4,136],'wall');return p;}
function r9FNeck(e,t){const q=rep(t),tilt=21*ease((q-.4)/.6)*RAD,p=model();p.view=16;plantedLegs(p);p.headUp=[Math.sin(tilt),0,Math.cos(tilt)];p.headRight=[Math.cos(tilt),0,-Math.sin(tilt)];p.head=V.add(p.shoulder,V.mul(p.headUp,15));armFK(p,-1,[-.05,0,-1],[0,0,-1]);const a=V.add(socket(p,1),[0,0,-46.8]),b=V.add(socket(p,1),[29,12,21]),c=V.add(p.head,V.add(V.mul(p.headRight,12),V.mul(p.headUp,6))),h=V.add(V.add(V.mul(a,(1-q)**2),V.mul(b,2*q*(1-q))),V.mul(c,q*q));arm(p,1,h,V.mix([.3,1,-.1],[1,1,0],ease((q-.75)/.25)));return p;}
const R9F_MODELS={45:r9FCrunch,60:r9FPike,110:r9FFigure,111:r9FBase,112:r9FCalfStretch,170:r9FNeck};
for(const key of Object.keys(MOTIONS)){const before=MOTIONS[key];MOTIONS[key]=(e,t)=>(R9F_MODELS[e.number]||before)(e,t);}

// Revision09: equipment clearance, natural dynamic poses and a shallower slam pickup.
const R9D_PREVIOUS={...MOTIONS};
function r9DBase(e,t){return R9D_PREVIOUS[e.motion](e,t);}
function r9DGetup(e,t){const p=r9DBase(e,t),h=p.j.rh;p.objects=p.objects.filter(o=>o.type!=='kettlebell');pipe(p,[[0,-4,0],[12,-4,-5],[12,4,-5],[0,4,0],[0,-4,0]].map(v=>V.add(h,v)),2,'grip');shape(p,'ball',{center:V.add(h,[12,0,-10]),radius:7});return p;}
function r9DBound(e,t){const p=r9DBase(e,t),a=2*Math.PI*t,land=Math.cos(a)**2,rise=5+3*land,shift=[0,0,rise],ends=[p.j.la,p.j.ra].map(v=>V.add(v,[0,0,-4*(1-land)]));p.hip=V.add(p.hip,shift);p.spine=p.spine.map(v=>V.add(v,shift));p.shoulder=p.spine.at(-1);p.head=V.add(p.head,shift);for(const key of ['le','re','lh','rh'])p.j[key]=V.add(p.j[key],shift);p.feet=[];p.contacts=[];for(const s of [-1,1]){leg(p,s,ends[s<0?0:1],[s*.2,1,0]);const ankle=p.j[s<0?'la':'ra'],knee=p.j[s<0?'lk':'rk'],blend=.65*ease((ankle[2]-4.3)/10),normal=V.unit(V.mix([0,0,1],V.unit(V.sub(knee,ankle)),blend));r4Foot(p,s,[0,1,0],normal);}return p;}
function r9DSlamBody(t,landingY){const h=keyValue(t,[[0,0],[.1,.08],[.30,1],[.60,1],[1,0]]),a=58*h*RAD,p=model([0,-3*h,61-31*h],[0,Math.sin(a),Math.cos(a)]);p.view=65;p.slamLandingY=landingY;for(const s of [-1,1])leg(p,s,[s*17,0,4.3],[0,1,0]);return p;}
function r9DSlamCenter(p,t){const bottom=r9DSlamBody(.6,p.slamLandingY).shoulder,follow=p.slamLandingY-bottom[1];let target;if(t<.60){const a=Math.PI*(1-ease(t/.24)),reach=Math.min(46.3,p.shoulder[2]-8);target=V.add(p.shoulder,[0,reach*Math.sin(a)+follow*ease((t-.24)/.36),-reach*Math.cos(a)]);}else{const q=ease((t-.60)/.40),a=Math.PI*q,reach=mix(bottom[2]-8,46.3,q);target=V.add(p.shoulder,[0,reach*Math.sin(a)+follow*(1-q),-reach*Math.cos(a)]);}const d=V.sub(target,p.shoulder);return V.add(p.shoulder,V.mul(V.unit(d),Math.min(46.3,V.len(d))));}
function r9DSlam(e,t){const release=.16,impact=.195,dt=impact-release,eps=1e-5,start=r9DSlamCenter(r9DSlamBody(release,0),release),left=r9DSlamCenter(r9DSlamBody(release-eps,0),release-eps),right=r9DSlamCenter(r9DSlamBody(release+eps,0),release+eps),velocity=V.mul(V.sub(right,left),1/(2*eps)),landingY=start[1]+velocity[1]*dt,landing=[0,landingY,8],p=r9DSlamBody(t,landingY),center=r9DSlamCenter(p,t);for(const s of [-1,1])arm(p,s,V.add(center,[s*6,0,0]),[s,0,0]);const held=V.mix(p.j.lh,p.j.rh,.5);let ball=held;if(t>=release&&t<impact){const u=t-release,acc=(8-start[2]-velocity[2]*dt)/(dt*dt);ball=[0,start[1]+velocity[1]*u,start[2]+velocity[2]*u+acc*u*u];}else if(t>=impact&&t<.6)ball=landing;shape(p,'ball',{center:ball,radius:8});p.j.ball=ball;return p;}
function r9DWrist(e,t){const p=model();p.view=45;plantedLegs(p);for(const s of [-1,1]){armFK(p,s,[s*.05,.82,-.57],[0,1,0]);const h=p.j[s<0?'lh':'rh'],a=2*Math.PI*t,d=V.unit([s*.18*Math.cos(a),1,.18*Math.sin(a)]),up=V.unit(V.sub([0,0,1],V.mul(d,d[2]))),right=V.unit(V.cross(d,up)),basis={right,forward:d,up};block(p,V.add(h,V.mul(d,2.2)),[4.5,5.2,4],'skin',basis);block(p,V.add(h,V.add(V.mul(d,1.8),V.add(V.mul(right,-s*2.1),V.mul(up,.8)))),[1.7,2.6,2.3],'skin',basis);p.j[s<0?'lfingertip':'rfingertip']=V.add(h,V.mul(d,4.8));}return p;}
function r9DRow(e,t){const q=rep(t),p=model([0,-10,35],[0,.1,.995]);p.view=60;seat(p,-10,28,false);for(const s of [-1,1])leg(p,s,[s*12,35.5,11],[0,1,0],-Math.PI/2);block(p,[0,42,11],[38,5,19],'metal');armFK(p,1,[.12,0,-1],[.06,.2,-1]);const start=V.add(p.shoulder,[-17,Math.sqrt(46.999**2-20),-2]),end=V.add(p.shoulder,[-17,16.5,-24]);arm(p,-1,V.mix(start,end,q),[-.3,-1,-1]);shape(p,'handle',{center:p.j.lh});const origin=[-17,83,75];r7DTower(p,origin,p.j.lh,Math.max(0,V.len(V.sub(p.j.lh,origin))-V.len(V.sub(start,origin))));return p;}
const R9D_MODELS={57:r9DGetup,86:r9DBound,90:r9DSlam,175:r9DWrist,190:r9DRow};
for(const key of Object.keys(MOTIONS)){const previous=MOTIONS[key];MOTIONS[key]=(e,t)=>(R9D_MODELS[e.number]||previous)(e,t);}



// Revision 10: compact neutral grips, direct triceps attachment, single wrist fists.
const R10H_PREVIOUS={...MOTIONS};
function r10HBase(e,t){return R10H_PREVIOUS[e.motion](e,t);}
function r10HHammer(e,t){
 const p=r10HBase(e,t),bells=p.objects.filter(o=>o.type==='dumbbell');
 p.objects=p.objects.filter(o=>o.type!=='dumbbell'&&!(o.type==='line'&&o.color==='skin'&&o.width===3.5));
 p.handStyle='custom';delete p.grip;p.r10HGrips=[];
 for(const bell of bells){
  const s=V.len(V.sub(bell.center,p.j.lh))<V.len(V.sub(bell.center,p.j.rh))?-1:1,
  h=p.j[s<0?'lh':'rh'],axis=V.unit(V.sub(h,p.j[s<0?'le':'re'])),
  out=V.unit(V.sub([s,0,0],V.mul(axis,axis[0]*s))),front=V.unit(V.cross(axis,out)),
  c=V.add(h,V.mul(out,6.3));
  // One palm, no additional knuckle/thumb cubes or outlined skin connector.
  block(p,V.add(h,V.mul(out,3.15)),[6.3,4.2,4.2],'skin',{right:out,forward:front,up:axis});
  pipe(p,[V.add(c,V.mul(axis,-8)),V.add(c,V.mul(axis,8))],2.5,'metal');
  for(const side of [-1,1])shape(p,'cylinder',{center:V.add(c,V.mul(axis,side*6)),axis,length:3.5,radius:3.3,color:'grip'});
  p.r10HGrips.push({side:s,center:c,axis,wrist:h,palmCenter:V.add(h,V.mul(out,3.15)),plateRadius:3.3});
 }
 return p;
}
function r10HTriceps(e,t){
 const p=r10HBase(e,t),bell=p.objects.find(o=>o.type==='dumbbell');
 if(!bell)return p;
 delete p.grip;
 // Keep the approved load trajectory exactly; cup the near plate at its two edges.
 for(const s of [-1,1])arm(p,s,V.add(V.add(bell.center,[s*6.8,0,0]),V.mul(bell.axis,-2)),[s*.25,0,1]);
 p.r10HGrips=[{center:bell.center,axis:bell.axis}];
 return p;
}
function r10HWrist(e,t){
 const p=r10HBase(e,t);p.handStyle='custom';delete p.grip;
 p.objects=p.objects.filter(o=>o.color!=='skin');
 for(const s of [-1,1]){
  const h=p.j[s<0?'lh':'rh'],a=2*Math.PI*t,d=V.unit([s*.18*Math.cos(a),1,.18*Math.sin(a)]),
  up=V.unit(V.sub([0,0,1],V.mul(d,d[2]))),right=V.unit(V.cross(d,up));
  // The whole fist is a single closed shape, joined directly to its wrist.
  block(p,V.add(h,V.mul(d,1.8)),[4.5,5.2,4],'skin',{right,forward:d,up});
  p.j[s<0?'lFingertip':'rFingertip']=V.add(h,V.mul(d,4.4));
 }
 return p;
}
const R10H_MODELS={21:r10HHammer,119:r10HTriceps,175:r10HWrist};
for(const key of Object.keys(MOTIONS)){const previous=MOTIONS[key];MOTIONS[key]=(e,t)=>(R10H_MODELS[e.number]||previous)(e,t);}

// Revision 10: only the latest reviews for 86, 112, and 170.
const R10F_PREVIOUS={...MOTIONS};
function r10FBase(e,t){return R10F_PREVIOUS[e.motion](e,t);}
function r10FBound(e,t){
 // Add depth in the direction of the trailing foot; both shoes remain distinct during the crossover.
 const p=r10FBase(e,t),spread=6*Math.sin(2*Math.PI*t)**2,depth=12*Math.sin(2*Math.PI*t)**2*Math.cos(2*Math.PI*t);
 const ends=[V.add(p.j.la,[-spread,depth,0]),V.add(p.j.ra,[spread,-depth,0])];
 p.feet=[];p.contacts=[];
 for(const s of [-1,1]){
  leg(p,s,ends[s<0?0:1],[s*.2,1,0]);
  const ankle=p.j[s<0?'la':'ra'],knee=p.j[s<0?'lk':'rk'];
  const blend=.65*ease((ankle[2]-4.3)/10),normal=V.unit(V.mix([0,0,1],V.unit(V.sub(knee,ankle)),blend));
  r4Foot(p,s,[0,1,0],normal);
 }
 return p;
}
function r10FCalf(e,t){
 const q=rep(t),c=Math.SQRT1_2,wallFace=35;
 const p=model([0,6*q,58.5+2*q],[0,.04+.21*q,1]);
 p.view=135;p.center=[0,4,0];
 leg(p,-1,[-9,-3,4.3],[0,1,0]);
 leg(p,1,[9,wallFace-13.5*c,9.5*c],[0,1,0]);
 r4Foot(p,1,[0,c,c],[0,-c,c]);
 for(const s of [-1,1])arm(p,s,[s*17,wallFace-2.9,89],[s*.2,-1,0]);
 block(p,[0,wallFace+2,68],[65,4,136],'wall');
 const f=p.feet.find(f=>f.s===1),sole=V.add(f.ankle,V.add(V.mul(f.forward,2),V.mul(f.up,-3.7)));
 p.contacts.push({kind:'foot',point:V.add(sole,V.add(V.mul(f.forward,-7.2),V.mul(f.up,-.6))),surface:'floor',height:0});
 p.contacts.push({kind:'foot',point:V.add(sole,V.add(V.mul(f.forward,7.2),V.mul(f.up,-.6))),surface:'wall',normal:[0,1,0],offset:wallFace});
 p.contacts.push({kind:'foot',point:V.add(p.j.la,[0,2,-4.3]),surface:'floor',height:0});
 return p;
}
function r10FNeck(e,t){
 const q=rep(t),lift=ease(q/.60),tilt=21*ease((q-.65)/.35)*RAD,p=model();
 p.view=16;
 for(const s of [-1,1])leg(p,s,[s*11,0,4.3],[0,1,0]);
 p.headUp=[Math.sin(tilt),0,Math.cos(tilt)];
 p.headRight=[Math.cos(tilt),0,-Math.sin(tilt)];
 p.head=V.add(p.shoulder,V.mul(p.headUp,15));
 armFK(p,-1,[-.05,0,-1],[-.02,0,-1]);
 // The rounded wrist touches the upper crown corner without the forearm passing through the hair.
 const o=socket(p,1),top=V.add(p.head,V.add(V.mul(p.headUp,12),V.mul(p.headRight,12)));
 if(q<.60){
  const neutralTop=V.add(p.shoulder,[12,0,27]),end=ik(o,neutralTop,24,23,[1,0,1]);
  const upper=V.sub(end.joint,o),lower=V.sub(neutralTop,end.joint);
  const ua=Math.atan2(upper[0],-upper[2])*lift;
  let lowerAngle=Math.atan2(lower[0],-lower[2]);if(lowerAngle<0)lowerAngle+=2*Math.PI;
  const la=lowerAngle*lift;
  armFK(p,1,[Math.sin(ua),0,-Math.cos(ua)],[Math.sin(la),0,-Math.cos(la)]);
 }else arm(p,1,top,[1,0,1]);
 return p;
}
const R10F_MODELS={86:r10FBound,112:r10FCalf,170:r10FNeck};
for(const key of Object.keys(MOTIONS)){const before=MOTIONS[key];MOTIONS[key]=(e,t)=>(R10F_MODELS[e.number]||before)(e,t);}

// Review round 10: apparatus-only revisions, with the accepted body motion retained.
const R10E_PREVIOUS={...MOTIONS};
function r10EBase(e,t){return R10E_PREVIOUS[e.motion](e,t);}
function r10EFork(p){const mid=V.mix(p.j.lh,p.j.rh,.5),half=V.len(V.sub(p.j.lh,p.j.rh))/2,r=Math.sqrt(28*28-half*half);return V.add(mid,[0,r*.98,r*Math.sqrt(1-.98**2)]);}
const R10E_CRUNCH_RANGES=new Map();
function r10ECrunch(e,t){
 const p=r10EBase(e,t),origin=[0,70,145],upper=[0,82,149],fork=r10EFork(p);
 if(!R10E_CRUNCH_RANGES.has(e.id)){let min=Infinity,max=-Infinity;for(let i=0;i<=2400;i++){const b=r10EBase(e,i/2400),d=V.len(V.sub(origin,r10EFork(b)));min=Math.min(min,d);max=Math.max(max,d);}R10E_CRUNCH_RANGES.set(e.id,{min,max});}
 const range=R10E_CRUNCH_RANGES.get(e.id),lift=V.len(V.sub(origin,fork))-range.min,stack=[0,82,29+lift];
 // Rebuild the route using this fork's travel. The moving stack takes up exactly
 // the length paid out to the athlete, without a saturated travel clamp.
 p.objects=[];mat(p);
 for(const s of [-1,1])pipe(p,[[s*10,82,4],[s*10,82,153]],2.4);
 block(p,[0,82,3],[35,32,5],'metal');block(p,stack,[16,12,40],'machine');
 for(let z=-15;z<=15;z+=6)pipe(p,[[-8,75.9,stack[2]+z],[8,75.9,stack[2]+z]],.6,'grip');
 cable(p,V.add(stack,[0,0,20]),upper,'cable',false);cable(p,upper,origin,'cable',false);cable(p,origin,fork,'cable',false);
 shape(p,'pulley',{center:upper});shape(p,'pulley',{center:origin});
 for(const s of [-1,1])pipe(p,[fork,p.j[s<0?'lh':'rh']],1.3,'rope');return p;
}
function r10EBandRow(e,t){
 const p=model([0,-10,58],[0,.45,.893]);p.view=60;plantedLegs(p);
 for(const s of [-1,1]){const origin=[s*13,67,3],near=[s*13,16,78],d=V.sub(near,socket(p,s)),v=V.sub(origin,near),a=V.dot(v,v),b=2*V.dot(d,v),c=V.dot(d,d)-46.9**2,u=(-b+Math.sqrt(b*b-4*a*c))/(2*a),far=V.add(near,V.mul(v,u));arm(p,s,V.mix(far,near,rep(t)),[s*.4,-1,-.2]);cable(p,origin,p.j[s<0?'lh':'rh'],'band',false);}
 pipe(p,[[-23,67,2],[23,67,2]],4);pipe(p,[[0,67,2],[0,67,18]],3);pipe(p,[[-15,67,3],[15,67,3]],3,'metal');return p;
}
function r10EGoodMorning(e,t){const p=r10EBase(e,t);p.objects=p.objects.filter(o=>!(o.type==='line'&&o.color==='band'));for(const s of [-1,1]){const h=V.add(p.shoulder,V.add(V.mul(p.right,s*19),V.add(V.mul(p.forward,9),V.mul(p.up,3))));arm(p,s,h,V.add(V.mul(p.right,s*.8),V.mul(p.up,-1)));pipe(p,[[s*16,4,1],p.j[s<0?'lh':'rh']],1.3,'band');}return p;}
function r10ERDL(e,t){const p=r10EBase(e,t);for(const o of p.objects)if(o.type==='dumbbell')o.axis=[o.axis[0],-o.axis[1],o.axis[2]];return p;}
const R10E_MODELS={45:r10ECrunch,71:r10EBandRow,77:r10EGoodMorning,82:r10ERDL};
for(const key of Object.keys(MOTIONS)){const before=MOTIONS[key];MOTIONS[key]=(e,t)=>(R10E_MODELS[e.number]||before)(e,t);}


// Round 11: reverse the bound's lateral lean and move the neck-stretch hand to the crown middle.
const R11F_PREVIOUS={...MOTIONS};
function r11FBase(e,t){return R11F_PREVIOUS[e.motion](e,t);}
function r11FBound(e,t){
 const p=r11FBase(e,t),old={up:p.up,forward:p.forward,right:p.right,shoulder:p.shoulder};
 const up=[-p.up[0],p.up[1],p.up[2]],next=model(p.hip,up);next.right=V.unit(V.cross(next.forward,next.up));
 const rotate=v=>V.add(V.add(V.mul(next.right,V.dot(v,old.right)),V.mul(next.forward,V.dot(v,old.forward))),V.mul(next.up,V.dot(v,old.up)));
 p.spine=p.spine.map(v=>V.add(p.hip,rotate(V.sub(v,p.hip))));p.shoulder=p.spine.at(-1);
 p.head=V.add(p.shoulder,rotate(V.sub(p.head,old.shoulder)));
 for(const key of ['le','re','lh','rh'])p.j[key]=V.add(p.shoulder,rotate(V.sub(p.j[key],old.shoulder)));
 p.up=next.up;p.forward=next.forward;p.right=next.right;
 return p;
}
function r11FNeck(e,t){
 const q=rep(t),lift=ease(q/.60),tilt=21*ease((q-.65)/.35)*RAD,p=model();p.view=16;
 for(const s of [-1,1])leg(p,s,[s*11,0,4.3],[0,1,0]);
 p.headUp=[Math.sin(tilt),0,Math.cos(tilt)];p.headRight=[Math.cos(tilt),0,-Math.sin(tilt)];
 p.head=V.add(p.shoulder,V.mul(p.headUp,15));armFK(p,-1,[-.05,0,-1],[-.02,0,-1]);
 // Crown midpoint across the head. The hand meets the front/top crown edge so the forearm stays outside the skull.
 const o=socket(p,1),top=V.add(p.head,V.add(V.mul(p.headUp,12),[0,10.5,0]));
 if(q<.60){
  const target=V.add(p.shoulder,[0,10.5,27]),end=ik(o,target,24,23,[0,1,1]);
  const upper=V.unit(V.sub(end.joint,o)),lower=V.unit(V.sub(target,end.joint));
  const ua=Math.acos(clamp(-upper[2],-1,1))*lift,la=(2*Math.PI-Math.acos(clamp(-lower[2],-1,1)))*lift;
  const uh=V.unit([upper[0],upper[1],0]),lh=V.unit([-lower[0],-lower[1],0]);
  armFK(p,1,[uh[0]*Math.sin(ua),uh[1]*Math.sin(ua),-Math.cos(ua)],[lh[0]*Math.sin(la),lh[1]*Math.sin(la),-Math.cos(la)]);
 }else arm(p,1,top,[0,1,1]);
 return p;
}
const R11F_MODELS={86:r11FBound,170:r11FNeck};
for(const key of Object.keys(MOTIONS)){const before=MOTIONS[key];MOTIONS[key]=(e,t)=>(R11F_MODELS[e.number]||before)(e,t);}

// Round 11: remove hammer-curl hands; align ropes and forearms with their load.
const R11E_PREVIOUS={...MOTIONS};
function r11EBase(e,t){return R11E_PREVIOUS[e.motion](e,t);}
function r11EHammer(e,t){const p=r11EBase(e,t);p.objects=[];p.handStyle='custom';delete p.grip;delete p.r10HGrips;for(const s of[-1,1]){const h=p.j[s<0?'lh':'rh'],forearm=V.unit(V.sub(h,p.j[s<0?'le':'re'])),out=V.unit(V.sub([s,0,0],V.mul(forearm,s*forearm[0]))),axis=V.unit(V.cross(forearm,out));pipe(p,[V.add(h,V.mul(axis,-8)),V.add(h,V.mul(axis,8))],2.5,'metal');for(const end of[-1,1])shape(p,'cylinder',{center:V.add(h,V.mul(axis,end*6)),axis,length:3.5,radius:3.3,color:'grip'});}return p;}
function r11EFork(p,origin){const mid=V.mix(p.j.lh,p.j.rh,.5),half=V.len(V.sub(p.j.lh,p.j.rh))/2;return V.add(mid,V.mul(V.unit(V.sub(origin,mid)),Math.sqrt(28*28-half*half)));}
function r11ECrunchPose(e,t){const p=r11EBase(e,t);for(const s of[-1,1])arm(p,s,V.add(p.j[s<0?'lh':'rh'],[0,12,0]),[s,0,0]);return p;}
const R11E_RANGES=new Map();
function r11ECrunch(e,t){const p=r11ECrunchPose(e,t),origin=[0,70,145],upper=[0,82,149],fork=r11EFork(p,origin);if(!R11E_RANGES.has(e.id)){let min=Infinity;for(let i=0;i<=2400;i++){const b=r11ECrunchPose(e,i/2400);min=Math.min(min,V.len(V.sub(origin,r11EFork(b,origin))));}R11E_RANGES.set(e.id,min);}const lift=V.len(V.sub(origin,fork))-R11E_RANGES.get(e.id),stack=[0,82,29+lift];p.objects=[];mat(p);for(const s of[-1,1])pipe(p,[[s*10,82,4],[s*10,82,153]],2.4);block(p,[0,82,3],[35,32,5],'metal');block(p,stack,[16,12,40],'machine');for(let z=-15;z<=15;z+=6)pipe(p,[[-8,75.9,stack[2]+z],[8,75.9,stack[2]+z]],.6,'grip');cable(p,V.add(stack,[0,0,20]),upper,'cable',false);cable(p,upper,origin,'cable',false);cable(p,origin,fork,'cable',false);shape(p,'pulley',{center:upper});shape(p,'pulley',{center:origin});for(const s of[-1,1])pipe(p,[fork,p.j[s<0?'lh':'rh']],1.3,'rope');return p;}
function r11EBandRow(e,t){const p=r11EBase(e,t);p.objects=p.objects.filter(o=>o.color!=='band');for(const s of[-1,1]){const origin=[s*13,67,3],angle=(30-105*rep(t))*RAD,L=Math.sqrt(24**2-5**2),elbow=V.add(socket(p,s),[s*5,L*Math.sin(angle),-L*Math.cos(angle)]),hand=V.add(elbow,V.mul(V.unit(V.sub(origin,elbow)),23));p.j[s<0?'le':'re']=elbow;p.j[s<0?'lh':'rh']=hand;cable(p,origin,hand,'band',false);}return p;}
const R11E_MODELS={21:r11EHammer,45:r11ECrunch,71:r11EBandRow};for(const key of Object.keys(MOTIONS)){const previous=MOTIONS[key];MOTIONS[key]=(e,t)=>(R11E_MODELS[e.number]||previous)(e,t);}


// Round 12: ease torso rotation through the middle of each lateral jump.
const R12_PREVIOUS={...MOTIONS};
function r12Bound(e,t){
 const p=R12_PREVIOUS[e.motion](e,t),slow=t+Math.sin(4*Math.PI*t)/(4*Math.PI),reference=R12_PREVIOUS[e.motion](e,slow);
 const old={up:p.up,forward:p.forward,right:p.right,shoulder:p.shoulder},next=model(p.hip,reference.up);
 next.right=V.unit(V.cross(next.forward,next.up));
 const rotate=v=>V.add(V.add(V.mul(next.right,V.dot(v,old.right)),V.mul(next.forward,V.dot(v,old.forward))),V.mul(next.up,V.dot(v,old.up)));
 p.spine=p.spine.map(v=>V.add(p.hip,rotate(V.sub(v,p.hip))));p.shoulder=p.spine.at(-1);
 p.head=V.add(p.shoulder,rotate(V.sub(p.head,old.shoulder)));
 for(const key of ['le','re','lh','rh'])p.j[key]=V.add(p.shoulder,rotate(V.sub(p.j[key],old.shoulder)));
 p.up=next.up;p.forward=next.forward;p.right=next.right;return p;
}
for(const key of Object.keys(MOTIONS)){const previous=MOTIONS[key];MOTIONS[key]=(e,t)=>e.number===86?r12Bound(e,t):previous(e,t);}
