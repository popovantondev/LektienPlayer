"""Render the localized application catalog from existing release metadata."""
from html import escape as e

COPY={
 'ru':dict(eyebrow='ПРИЛОЖЕНИЯ ДЛЯ MACOS И WINDOWS',title='Ваши задачи. Нужные инструменты.',intro='Учёба, медиа, резервные копии и повседневная работа. Выберите программу — загрузка и руководство рядом.',all='Все программы',search='Найти программу',placeholder='Название или задача…',requirements='Требования и ограничения',count='программ',empty='Ничего не найдено. Измените поиск или платформу.',github='Открыть GitHub',browse='Выбрать программу',footer='Проверяйте требования перед загрузкой. Preview — предварительная версия; «Исходники» означает отсутствие готового пакета.',platform='Платформа'),
 'de':dict(eyebrow='ANWENDUNGEN FÜR MACOS UND WINDOWS',title='Ihre Aufgaben. Die passenden Werkzeuge.',intro='Lernen, Medien, Backups und alltägliche Arbeit. Anwendung auswählen — Download und Anleitung sind direkt dabei.',all='Alle Anwendungen',search='Anwendung suchen',placeholder='Name oder Aufgabe…',requirements='Voraussetzungen und Grenzen',count='Anwendungen',empty='Keine Ergebnisse. Suche oder Plattform ändern.',github='GitHub öffnen',browse='Anwendung auswählen',footer='Voraussetzungen vor dem Download prüfen. Preview ist eine Vorabversion; „Quellcode“ bedeutet, dass kein fertiges Paket verfügbar ist.',platform='Plattform'),
 'en':dict(eyebrow='APPLICATIONS FOR MACOS AND WINDOWS',title='Your tasks. The right tools.',intro='Study, media, backups and everyday work. Choose an application — downloads and guides are right beside it.',all='All applications',search='Find an application',placeholder='Name or task…',requirements='Requirements and limitations',count='applications',empty='No matches. Change your search or platform.',github='Open GitHub',browse='Explore applications',footer='Check requirements before downloading. Preview is an early release; “Source” means there is no ready-to-run package.',platform='Platform')}

PERMISSION_NOTICE={
 'ru':'Только с разрешения всех участников — для каждой встречи.',
 'de':'Nur mit Zustimmung aller Beteiligten — vor jeder Besprechung.',
 'en':'Only with every participant’s permission — for each meeting.'}

def render(d,l,labels,status,actions):
 c=COPY[l]; nav=''.join(f'<a href="{("index.html" if x=="en" else "index-"+x+".html")}" lang="{x}" hreflang="{x}"'+(' aria-current="page"' if x==l else '')+f'>{dict(ru="RU",de="DE",en="EN")[x]}</a>' for x in ('ru','de','en'))
 title=' '.join('<span>'+e(part)+'</span>' for part in {'ru':['Ваши задачи.','Нужные инструменты.'],'de':['Ihre Aufgaben.','Die passenden Werkzeuge.'],'en':['Your tasks.','The right tools.']}[l])
 cards=[]
 for p in d['projects']:
  os='macos' if 'macOS' in p['platform'] else 'windows'
  icon=d['catalog_icons'][p['repo']]
  notice=f'<p class="collection-notice">{e(PERMISSION_NOTICE[l])}</p>' if p['repo']=='SaveLecture' else ''
  links=actions(p,l)
  website=p.get('navigation',{}).get(l,{}).get('website') or d.get('catalog_websites',{}).get(p['repo'],{}).get(l)
  title_url=website or p['source_url']
  demo=next(((label,url) for label,url in links if p['repo']=='PeakMP3' and url.endswith('#demo')),None)
  if demo:
   links=[(label,url) for label,url in links if url!=demo[1]]
  demo_link=f'<a class="try-demo" href="{e(demo[1])}">{e(demo[0])} <span aria-hidden="true">↗</span></a>' if demo else ''
  cards.append(f'''<article class="project" id="{e(p['repo'])}" data-platform="{os}">
<div class="project-heading"><img class="project-icon" src="{e(icon)}" width="64" height="64" alt="" decoding="async" loading="lazy"><span class="platform">{e(p['platform'])}</span></div>
<div class="project-title-row"><h2><a href="{e(title_url)}">{e(p['name'])}</a></h2>{demo_link}</div><span class="status {p['status']}">{e(status(p,l))}</span>
<p class="description">{e(p['description'][l])}</p>{notice}
<details class="requirements"><summary>{e(c['requirements'])}</summary><p>{e(p['requirements'][l])}</p></details>
<div class="actions">{''.join(f'<a{(' class="support-link"' if url==p['feedback_url'] else '')} href="{e(url)}">{e(label)}</a>' for label,url in links)}</div></article>''')
 n=len(d['projects'])
 return f'''<!doctype html>
<html lang="{l}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="description" content="{e(c['intro'])}"><meta name="theme-color" content="#f6f7fb"><title>popovantondev — {e(labels[l]['catalog'])}</title><link rel="stylesheet" href="assets/catalog.css?v=studio-20261022"><script src="assets/catalog.js?v=studio-20261022" defer></script></head>
<body><div class="shell"><header class="top"><a class="brand" href="https://github.com/popovantondev">popovantondev</a><nav aria-label="Language">{nav}</nav></header>
<main><section class="hero hero-studio"><div class="studio-art" aria-hidden="true"><div class="scene"><img class="photograph" src="assets/studio/studio-desktops.webp" width="2048" height="768" alt="" aria-hidden="true"><div class="desktop mac-desktop" style="transform:matrix3d(0.362478164855,0.00268640514118,0,2.11527963873e-05,-0.00544406398359,0.354618133095,0,-2.39855755711e-05,0,0,1,0,91,127,0,1)" aria-hidden="true"><img class="app translator" src="assets/studio/translate-{l}.webp" alt=""><div class="sender-window"><div class="titlebar"><span class="traffic"><i></i><i></i><i></i></span>Telegram Media Sender</div><img src="assets/studio/sender-{l}.webp" alt=""></div></div><div class="desktop windows-desktop" style="transform:matrix3d(0.307737845066,-0.00272982638239,0,-1.96390387222e-05,-0.0464419135057,0.323316632667,0,-2.52904813132e-05,0,0,1,0,1407,139,0,1)" aria-hidden="true"><img class="app peak" src="assets/studio/peak-{l}.webp" alt=""><img class="app quick" src="assets/studio/quick-{l}.webp" alt=""></div></div></div><div class="hero-copy"><p class="eyebrow">{e(c['eyebrow'])}</p><h1>{title}</h1><p class="lead">{e(c['intro'])}</p><div class="hero-actions"><a class="primary" href="#catalog">{e(c['browse'])} <span aria-hidden="true">↘</span></a><a href="https://github.com/popovantondev">{e(c['github'])} <span aria-hidden="true">↗</span></a></div><div class="hero-meta"><span>{n} {e(c['count'])}</span><span>macOS / Windows</span><span>RU / DE / EN</span></div></div></section>
<a class="peak-demo-feature" href="https://popovantondev.github.io/PeakMP3/index-{l}.html#demo"><img src="assets/peakmp3-demo-{l}.svg" width="1400" height="520" alt="PeakMP3 — {dict(ru='Попробовать в браузере',de='Im Browser testen',en='Try in browser')[l]}" loading="lazy"></a>
<section id="catalog" aria-labelledby="catalog-title"><div class="catalog-top"><div><p class="eyebrow">{e(c['platform'])} · macOS / Windows</p><h2 id="catalog-title">{e(c['all'])}</h2></div><span class="result-count" id="result-count" aria-live="polite">{n} / {n}</span></div>
<div class="catalog-controls" hidden><div class="filters" role="group" aria-label="{e(c['platform'])}"><button type="button" data-filter="all" aria-pressed="true">{e(c['all'])}</button><button type="button" data-filter="macos" aria-pressed="false">macOS</button><button type="button" data-filter="windows" aria-pressed="false">Windows</button></div><label class="search"><span class="sr-only">{e(c['search'])}</span><input id="project-search" type="search" placeholder="{e(c['placeholder'])}" autocomplete="off"></label></div>
<div class="projects">{''.join(cards)}</div><p class="empty" id="empty" hidden>{e(c['empty'])}</p></section></main>
<footer><a href="https://github.com/popovantondev">popovantondev <span aria-hidden="true">↗</span></a><p>{e(c['footer'])}</p><span>RU · DE · EN</span></footer></div></body></html>
'''
