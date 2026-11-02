'use strict';
const steps = JSON.parse(document.getElementById('workflow-data').textContent);
const languagePicker = document.querySelector('.language-picker');
document.addEventListener('pointerdown', e => {
 if (!languagePicker.contains(e.target)) languagePicker.open = false;
});
document.addEventListener('keydown', e => {
 if (e.key === 'Escape' && languagePicker.open) {
  languagePicker.open = false;
  languagePicker.querySelector('summary').focus();
 }
});
const tabs = [...document.querySelectorAll('.step')];
function showStep(i,focus=false){
 tabs.forEach((tab,n)=>{tab.classList.toggle('active',i===n);tab.setAttribute('aria-selected',String(i===n));tab.tabIndex=i===n?0:-1});
 const item=steps[i];for(const [id,key] of [['step-kicker','kicker'],['step-title','title'],['step-copy','copy'],['slate-title','slate'],['slate-step','label']]) document.getElementById(id).textContent=item[key];
 const list=document.getElementById('step-points');list.replaceChildren(...item.points.map(text=>{const li=document.createElement('li');li.textContent=text;return li}));
 document.getElementById('step-panel').setAttribute('aria-labelledby',`tab-${i}`);
 if(focus)tabs[i].focus();
}
tabs.forEach((tab,i)=>{tab.addEventListener('click',()=>showStep(i));tab.addEventListener('keydown',e=>{let n;if(e.key==='ArrowRight')n=(i+1)%tabs.length;if(e.key==='ArrowLeft')n=(i+tabs.length-1)%tabs.length;if(e.key==='Home')n=0;if(e.key==='End')n=tabs.length-1;if(n!==undefined){e.preventDefault();showStep(n,true)}})});
document.getElementById('slate-title').style.whiteSpace='pre-line';
const box=document.querySelector('.lightbox');let opener;
document.querySelectorAll('[data-lightbox]').forEach(button=>button.addEventListener('click',()=>{opener=button;const img=box.querySelector('img');img.src=button.dataset.lightbox;img.alt=button.querySelector('img').alt;box.showModal()}));
box.querySelector('.lightbox-close').addEventListener('click',()=>box.close());
box.addEventListener('click',e=>{if(e.target===box){const r=box.getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)box.close()}});
box.addEventListener('close',()=>opener?.focus());
