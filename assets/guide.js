// The guide's behaviour: the sidebar on narrow screens, the copy buttons on
// code blocks, the "on this page" highlight, and the search.
//
// The search index (search-index.js, written by the generator) is loaded the
// first time the search box is used. It is a script rather than JSON so that
// the site also works from file:// URLs, where fetch() is refused.
(function () {
  "use strict";

  var root = document.documentElement.getAttribute("data-root") || "";

  // The sidebar ---------------------------------------------------------------

  var toggle = document.querySelector(".nav-toggle");
  function setNav(open) {
    document.body.classList.toggle("nav-open", open);
    if (toggle) toggle.setAttribute("aria-expanded", open ? "true" : "false");
  }
  if (toggle) {
    toggle.addEventListener("click", function () {
      setNav(!document.body.classList.contains("nav-open"));
    });
  }
  document.addEventListener("click", function (e) {
    if (!document.body.classList.contains("nav-open")) return;
    var sidebar = document.getElementById("sidebar");
    if (e.target.closest && (e.target.closest(".nav-toggle") || (sidebar.contains(e.target) && !e.target.closest("a")))) return;
    setNav(false);
  });

  var current = document.querySelector('.tree a[aria-current="page"]');
  if (current && current.scrollIntoView) {
    var sidebarEl = document.getElementById("sidebar");
    var top = current.offsetTop - sidebarEl.clientHeight / 3;
    if (top > 0) sidebarEl.scrollTop = top;
  }

  // Copy buttons ----------------------------------------------------------------

  document.querySelectorAll(".code-block").forEach(function (block) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "copy";
    button.textContent = "Copy";
    button.addEventListener("click", function () {
      var text = block.querySelector("pre").innerText;
      var done = function () {
        button.textContent = "Copied";
        setTimeout(function () { button.textContent = "Copy"; }, 1500);
      };
      if (navigator.clipboard) navigator.clipboard.writeText(text).then(done, function () {});
    });
    block.appendChild(button);
  });

  // The section being read, in the sidebar's "on this page" list --------------

  var onPage = document.querySelectorAll(".on-page a");
  if (onPage.length && "IntersectionObserver" in window) {
    var links = {};
    onPage.forEach(function (a) { links[decodeURIComponent(a.hash.slice(1))] = a; });
    var headings = Array.prototype.filter.call(document.querySelectorAll(".prose h2[id]"), function (h) { return links[h.id]; });
    var update = function () {
      var line = window.innerHeight * 0.25, active = null;
      headings.forEach(function (h) { if (h.getBoundingClientRect().top < line) active = h; });
      onPage.forEach(function (a) { a.classList.remove("active"); });
      if (active) links[active.id].classList.add("active");
    };
    var observer = new IntersectionObserver(update, { rootMargin: "0px 0px -70% 0px" });
    headings.forEach(function (h) { observer.observe(h); });
    update();
  }

  // Search ----------------------------------------------------------------------

  var input = document.getElementById("search-input");
  var panel = document.getElementById("search-results");
  if (!input || !panel) return;

  var index = null;      // the prepared index, once loaded
  var loading = false;
  var selected = -1;

  function load() {
    if (index || loading) return;
    loading = true;
    var script = document.createElement("script");
    script.src = root + "assets/search-index.js";
    script.onload = function () {
      index = prepare(window.HMSSQL_SEARCH);
      if (input.value.trim()) search();
    };
    document.head.appendChild(script);
  }

  function prepare(data) {
    return {
      pages: data.pages.map(function (p) {
        return { url: p[0], title: p[1], section: p[2], lower: p[1].toLowerCase() };
      }),
      sections: data.sections.map(function (s) {
        return {
          page: s[0], heading: s[1], anchor: s[2], prose: s[3], code: s[4],
          lh: s[1].toLowerCase(), lp: s[3].toLowerCase(), lc: s[4].toLowerCase()
        };
      }),
      api: data.api.map(function (a) {
        return { name: a[0], module: a[1], href: a[2], lower: a[0].toLowerCase(), lmod: a[1].toLowerCase() };
      })
    };
  }

  function isWordStart(text, at) {
    return at === 0 || !/[a-z0-9_]/.test(text.charAt(at - 1));
  }

  function count(text, term) {
    var n = 0, at = text.indexOf(term);
    while (at !== -1 && n < 8) { n++; at = text.indexOf(term, at + term.length); }
    return n;
  }

  // A section matches when every term appears in its page's title, its
  // heading, its prose or its code. Headings and titles weigh most, and a
  // match at the start of a word beats one inside it.
  function scoreSection(s, page, terms) {
    var score = 0;
    for (var i = 0; i < terms.length; i++) {
      var t = terms[i];
      var inTitle = page.lower.indexOf(t), inHeading = s.lh.indexOf(t);
      var inProse = s.lp.indexOf(t), inCode = s.lc.indexOf(t);
      if (inTitle < 0 && inHeading < 0 && inProse < 0 && inCode < 0) return 0;
      if (inTitle >= 0) score += 6 + (isWordStart(page.lower, inTitle) ? 3 : 0);
      if (inHeading >= 0) score += 10 + (isWordStart(s.lh, inHeading) ? 4 : 0);
      if (inProse >= 0) score += 2 + Math.min(count(s.lp, t), 6) + (isWordStart(s.lp, inProse) ? 1 : 0);
      if (inCode >= 0) score += 1 + Math.min(count(s.lc, t), 3) * 0.5;
    }
    return score;
  }

  function scoreApi(a, query, terms) {
    var q = query.replace(/\s+/g, "");
    var score = 0;
    if (a.lower === q) score = 100;
    else if (a.lower.indexOf(q) === 0) score = 60 - Math.min(a.lower.length - q.length, 30);
    else if (a.lower.indexOf(q) > 0) score = 25 - Math.min(a.lower.length - q.length, 20);
    else if (terms.length > 1 && terms.every(function (t) { return a.lower.indexOf(t) >= 0 || a.lmod.indexOf(t) >= 0; })) score = 10;
    if (!score) return 0;
    if (a.module === "module") score += 2;
    if (/\.(Internal|Unsafe|Lexer)\b|^Hmssql\.Tds\b/.test(a.module)) score -= 8;
    return score;
  }

  function escapeHtml(s) {
    return s.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  function escapeRegExp(s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }

  function highlight(text, terms) {
    if (!terms.length) return escapeHtml(text);
    var re = new RegExp("(" + terms.map(escapeRegExp).join("|") + ")", "gi");
    return text.split(re).map(function (part, i) {
      return i % 2 ? "<mark>" + escapeHtml(part) + "</mark>" : escapeHtml(part);
    }).join("");
  }

  // About 160 characters of the text around the first term it contains.
  function snippet(text, lower, terms) {
    var at = -1;
    for (var i = 0; i < terms.length; i++) {
      var j = lower.indexOf(terms[i]);
      if (j >= 0 && (at < 0 || j < at)) at = j;
    }
    if (at < 0) at = 0;
    var start = Math.max(0, at - 60);
    if (start > 0) {
      var space = text.indexOf(" ", start);
      if (space >= 0 && space < at) start = space + 1;
    }
    var end = Math.min(text.length, start + 170);
    if (end < text.length) {
      var lastSpace = text.lastIndexOf(" ", end);
      if (lastSpace > at) end = lastSpace;
    }
    return (start > 0 ? "… " : "") + highlight(text.slice(start, end), terms) + (end < text.length ? " …" : "");
  }

  function search() {
    var query = input.value.trim().toLowerCase();
    selected = -1;
    if (!query) { close(); return; }
    if (!index) { load(); return; }
    var terms = query.split(/\s+/).filter(Boolean);

    var byPage = {};
    index.sections.forEach(function (s) {
      var score = scoreSection(s, index.pages[s.page], terms);
      if (!score) return;
      (byPage[s.page] = byPage[s.page] || []).push({ s: s, score: score });
    });
    var pages = Object.keys(byPage).map(function (p) {
      var hits = byPage[p].sort(function (a, b) { return b.score - a.score; });
      var total = hits[0].score + hits.slice(1).reduce(function (n, h) { return n + h.score * 0.15; }, 0);
      return { page: index.pages[p], hits: hits.slice(0, 3), score: total };
    }).sort(function (a, b) { return b.score - a.score; }).slice(0, 8);

    var api = index.api.map(function (a) { return { a: a, score: scoreApi(a, query, terms) }; })
      .filter(function (x) { return x.score > 0; })
      .sort(function (x, y) { return y.score - x.score || x.a.name.length - y.a.name.length; })
      .slice(0, 8);

    var html = "";
    var exactApi = api.length && api[0].score >= 100;
    var guideHtml = "", apiHtml = "";
    if (pages.length) {
      guideHtml += '<div class="sr-group">Guide</div>';
      pages.forEach(function (r) {
        var url = root + r.page.url;
        var intro = r.hits.filter(function (h) { return !h.s.anchor; })[0];
        guideHtml += '<a class="sr-item" role="option" href="' + url + '"><span class="sr-title">' +
          highlight(r.page.title, terms) + (r.page.section ? '<span class="sr-crumb">' + escapeHtml(r.page.section) + "</span>" : "") + "</span>" +
          (intro ? '<span class="sr-snippet">' + snippet(intro.s.prose || intro.s.code, intro.s.prose ? intro.s.lp : intro.s.lc, terms) + "</span>" : "") +
          "</a>";
        r.hits.forEach(function (h) {
          if (!h.s.anchor) return;
          var text = h.s.prose, lower = h.s.lp;
          if (!terms.some(function (t) { return lower.indexOf(t) >= 0; }) && h.s.code) { text = h.s.code; lower = h.s.lc; }
          guideHtml += '<a class="sr-sub" role="option" href="' + url + "#" + h.s.anchor + '"><span class="sr-heading">' +
            highlight(h.s.heading, terms) + '</span><span class="sr-snippet">' + snippet(text, lower, terms) + "</span></a>";
        });
      });
    }
    if (api.length) {
      apiHtml += '<div class="sr-group">API reference</div>';
      api.forEach(function (x) {
        apiHtml += '<a class="sr-item sr-api" role="option" href="' + root + "api/" + x.a.href + '"><code>' +
          highlight(x.a.name, terms) + '</code><span class="sr-module">' +
          (x.a.module === "module" ? "module" : escapeHtml(x.a.module)) + "</span></a>";
      });
    }
    // A query that matches a name, and no page's title, is most likely a
    // name being looked up, so the API comes first.
    var titleHit = pages.some(function (r) {
      return terms.every(function (t) { return r.page.lower.indexOf(t) >= 0; });
    });
    html = exactApi || (api.length && api[0].score >= 40 && !titleHit) ? apiHtml + guideHtml : guideHtml + apiHtml;
    if (!html) html = '<div class="sr-empty">Nothing matches “' + escapeHtml(input.value.trim()) + "”.</div>";
    else html += '<div class="sr-hint"><kbd>↑</kbd> <kbd>↓</kbd> to choose, <kbd>Enter</kbd> to open, <kbd>Esc</kbd> to close</div>';
    panel.innerHTML = html;
    panel.hidden = false;
    input.setAttribute("aria-expanded", "true");
    panel.scrollTop = 0;
  }

  function close() {
    panel.hidden = true;
    input.setAttribute("aria-expanded", "false");
    selected = -1;
  }

  function options() {
    return panel.querySelectorAll("a");
  }

  function select(i) {
    var all = options();
    if (!all.length) return;
    selected = (i + all.length) % all.length;
    all.forEach(function (a, j) { a.classList.toggle("selected", j === selected); });
    all[selected].scrollIntoView({ block: "nearest" });
  }

  input.addEventListener("focus", function () { load(); if (input.value.trim()) search(); });
  input.addEventListener("input", search);
  input.addEventListener("keydown", function (e) {
    if (e.key === "ArrowDown") { e.preventDefault(); select(selected + 1); }
    else if (e.key === "ArrowUp") { e.preventDefault(); select(selected - 1); }
    else if (e.key === "Enter") {
      var all = options();
      var target = all[selected >= 0 ? selected : 0];
      if (target) { e.preventDefault(); close(); window.location.href = target.href; }
    } else if (e.key === "Escape") {
      if (!panel.hidden) close(); else input.blur();
    }
  });
  panel.addEventListener("mousemove", function (e) {
    var a = e.target.closest("a");
    if (!a) return;
    var all = Array.prototype.indexOf.call(options(), a);
    if (all !== selected) select(all);
  });
  panel.addEventListener("click", function () { close(); });
  document.addEventListener("click", function (e) {
    if (!e.target.closest(".search")) close();
  });
  document.addEventListener("keydown", function (e) {
    if (e.key !== "/" || e.ctrlKey || e.metaKey || e.altKey) return;
    var t = e.target;
    if (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName)) return;
    e.preventDefault();
    input.focus();
    input.select();
  });
})();
