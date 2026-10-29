const canvas={width:640,height:480};
const ctx={canvas,createImageData:(w,h)=>({width:w,height:h,data:new Uint8ClampedArray(w*h*4)}),putImageData:(img)=>{ctx.last=img;}};
const ids=['exercise-001','exercise-086','exercise-150','exercise-199'];
for(const id of ids){
 const e=movements.find(m=>m.id===id);
 let t0=Date.now();
 for(let i=0;i<24;i++) renderExercise(ctx,e,i/24,'male','exercise');
 print(id, e.name, ((Date.now()-t0)/24).toFixed(1)+' ms/frame');
}
