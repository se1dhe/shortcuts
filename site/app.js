'use strict';
const steps = [
 {kicker:'КРОК 01 · ДЖЕРЕЛО',title:'Почніть із фільму',copy:'Додайте локальне відео або виберіть фільм із бібліотеки контент-плану. Підготуйте MP4 та потрібну аудіодоріжку.',points:['Локальна транскрипція WhisperKit','Контроль мови й походження субтитрів','Керована підготовка джерела та очищення MKV'],slate:'Історія\nпочинається тут.',label:'01 / ФІЛЬМ'},
 {kicker:'КРОК 02 · ЕСЕ',title:'Тема, підкріплена сценами',copy:'Director аналізує репліки та події, пропонує тему й план. Оберіть емоційну історію у чотирьох актах або аналітичне есе у п’яти.',points:['Каталог сцен і докази для теми','Перевірки структури, меж та повторів','Ручний монтаж і перегляд кожної сцени'],slate:'Від кадру\nдо сенсу.',label:'02 / ЕСЕ'},
 {kicker:'КРОК 03 · SHORTS',title:'Сильні моменти всього фільму',copy:'Знайдіть самостійні сцени, що чіпляють з першої секунди. Відбір не обмежується монтажем готового есе.',points:['Візуальна перевірка реальних фрагментів','Власний монтаж і текст для кожного ролика','Коротка картка фільму та стриманий логотип'],slate:'Момент,\nякий лишається.',label:'03 / SHORTS'},
 {kicker:'КРОК 04 · ВИПУСК',title:'Оформіть і перевірте результат',copy:'Підготуйте обкладинку, заголовок, опис, розділи та закріплений коментар. Перегляньте все перед відправленням.',points:['Варіанти обкладинок із глибиною','YouTube, TikTok і Telegram після налаштування','Окремі статуси й підтвердження публікацій'],slate:'Історія\nзнаходить глядача.',label:'04 / ВИПУСК'}
];
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
