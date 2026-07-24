// 中 / 日 / 英切换：只显示对应 <article lang="...">，选择记在 localStorage。
(function () {
  var bar = document.querySelector('.langs');
  function pick(l) {
    document.querySelectorAll('article').forEach(function (a) { a.hidden = a.lang !== l; });
    bar.querySelectorAll('button').forEach(function (b) { b.classList.toggle('on', b.dataset.l === l); });
    document.documentElement.lang = l;
    try { localStorage.setItem('lp-legal-lang', l); } catch (e) {}
  }
  bar.addEventListener('click', function (e) { if (e.target.dataset.l) pick(e.target.dataset.l); });
  var saved;
  try { saved = localStorage.getItem('lp-legal-lang'); } catch (e) {}
  var nav = (navigator.language || 'en').toLowerCase();
  pick(saved || (nav.indexOf('ja') === 0 ? 'ja' : nav.indexOf('zh') === 0 ? 'zh' : 'en'));
})();
