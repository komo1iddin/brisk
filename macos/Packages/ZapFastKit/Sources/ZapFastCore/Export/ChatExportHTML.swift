import Foundation

/// An export's pages: the conversation as a web page, in sequence, with the
/// day it happened under a heading, who wrote each message beside it, ours on
/// the right and theirs on the left, and the media inside the message. One
/// file with its style and its few lines of script inside; it reaches nothing
/// but the folder's own media.
nonisolated enum ChatExportHTML {
    /// A message and the file its attachment was written to (a path inside
    /// the export folder), if it was written.
    struct Placed: Sendable {
        let entry: ChatExportEntry
        let file: String?
    }

    struct Page: Sendable {
        let title: String
        /// Everyone who wrote in the chat, in the order they first did.
        let participants: [String]
        /// The first and last day of the whole chat, as written under a heading.
        let firstDay: String?
        let lastDay: String?
        /// 1-based, of `pages`.
        let number: Int
        let pages: Int
        let messages: Int
        let exported: String
        let language: String
        let items: [Placed]
    }

    /// The file name of a page: `messages.html`, `messages2.html`, ...
    static func fileName(page number: Int) -> String {
        number == 1 ? "messages.html" : "messages\(number).html"
    }

    static func render(_ page: Page) -> String {
        var html = """
        <!DOCTYPE html>
        <html lang="\(escape(page.language))">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(page.title))</title>
        <style>\(style)</style>
        </head>
        <body>
        \(header(page))
        <div class="wrap">

        """
        html += navigation(page)
        html += "<main>\n"
        var previous: Placed?
        for placed in page.items {
            let entry = placed.entry
            if previous?.entry.day != entry.day {
                html += "<div class=\"day\"><span>\(escape(entry.day))</span></div>\n"
                previous = nil
            }
            let continues = previous.map {
                $0.entry.author == entry.author && $0.entry.fromMe == entry.fromMe
                    && entry.timestamp - $0.entry.timestamp < 5 * 60
            } ?? false
            html += message(placed, continues: continues)
            previous = placed
        }
        html += "</main>\n"
        html += navigation(page)
        html += "</div>\n<script>\(script)</script>\n</body>\n</html>\n"
        return html
    }

    // MARK: The top

    private static func header(_ page: Page) -> String {
        var lines: [String] = []
        if !page.participants.isEmpty {
            let who = page.participants.count <= 4
                ? page.participants.joined(separator: ", ")
                : String(localized: "\(page.participants.count) people")
            lines.append(who)
        }
        if let first = page.firstDay, let last = page.lastDay {
            lines.append(first == last ? first : "\(first) – \(last)")
        }
        lines.append(String(localized: "\(page.messages) messages, exported \(page.exported)"))
        return """
        <header><div class="top">
        \(avatar(page.title, large: true))
        <div><h1 dir="auto">\(escape(page.title))</h1>
        <p dir="auto">\(lines.map(escape).joined(separator: " · "))</p></div>
        </div></header>
        """
    }

    // MARK: A message

    private static func message(_ placed: Placed, continues: Bool) -> String {
        let entry = placed.entry
        var classes = entry.fromMe ? "row out" : "row in"
        if continues { classes += " cont" }
        var html = "<div class=\"\(classes)\" id=\"m\(escape(anchor(entry.id)))\">"
        html += continues ? "<span class=\"av gap\"></span>" : avatar(entry.author)
        html += "<div class=\"bubble\">\n"
        if !continues {
            html += "<div class=\"who\" style=\"--h:\(hue(of: entry.author))\" dir=\"auto\">\(escape(entry.author))</div>\n"
        }
        if entry.forwarded {
            html += "<div class=\"fwd\">↪ \(escape(String(localized: "Forwarded")))</div>\n"
        }
        if let reply = entry.reply {
            html += "<blockquote style=\"--h:\(hue(of: reply.author))\" dir=\"auto\"><b>\(escape(reply.author))</b>\(escape(reply.summary))</blockquote>\n"
        }
        html += body(entry.body, file: placed.file)
        var meta = escape(entry.time)
        if entry.edited { meta = escape(String(localized: "edited")) + " " + meta }
        html += "<div class=\"meta\">\(meta)</div>\n"
        if !entry.reactions.isEmpty {
            html += "<div class=\"reactions\">"
            for reaction in entry.reactions {
                html += "<span>\(escape(reaction.emoji))\(reaction.count > 1 ? " \(reaction.count)" : "")</span>"
            }
            html += "</div>\n"
        }
        html += "</div></div>\n"
        return html
    }

    /// A round avatar with the person's initials, in their own colour.
    private static func avatar(_ name: String, large: Bool = false) -> String {
        "<span class=\"av\(large ? " big" : "")\" style=\"--h:\(hue(of: name))\" aria-hidden=\"true\">\(escape(initials(of: name)))</span>"
    }

    /// The first letters of the first two words ("Ilhomjon Rustamov" is "IR");
    /// the tilde WhatsApp puts before a profile name is not one.
    static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "~" }).prefix(2)
        let letters = words.compactMap { $0.first(where: { $0.isLetter || $0.isNumber }) }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private static func body(_ body: ChatExportBody, file: String?) -> String {
        switch body {
        case .html(let html):
            return "<div class=\"text\" dir=\"auto\">\(html)</div>\n"
        case let .media(kind, _, name, bytes, seconds, caption, waveform):
            var html = media(kind: kind, file: file, name: name, bytes: bytes, seconds: seconds, waveform: waveform)
            if !caption.isEmpty { html += "<div class=\"text\" dir=\"auto\">\(caption)</div>\n" }
            return html
        }
    }

    private static func media(
        kind: ChatExportMediaKind, file: String?, name: String?, bytes: UInt64, seconds: UInt32?, waveform: [UInt8]
    ) -> String {
        guard let file else {
            return "<div class=\"omitted\">\(escape(omitted(kind, name: name)))</div>\n"
        }
        let href = escape(path(file))
        switch kind {
        case .photo:
            return "<a class=\"media\" data-photo href=\"\(href)\"><img src=\"\(href)\" loading=\"lazy\" decoding=\"async\" alt=\"\"></a>\n"
        case .sticker:
            return "<img class=\"sticker\" src=\"\(href)\" loading=\"lazy\" alt=\"\">\n"
        case .video:
            // The first frame is the picture until it plays.
            let length = seconds.map { "<small>\(escape(duration($0)))</small>" } ?? ""
            return "<video class=\"media\" controls preload=\"metadata\" src=\"\(href)#t=0.1\"></video>\(length)\n"
        case .voice, .audio:
            return player(href: href, seconds: seconds, waveform: kind == .voice ? waveform : [])
        case .document:
            let title = name ?? (file as NSString).lastPathComponent
            let size = bytes > 0 ? "<small>\(escape(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))</small>" : ""
            return """
            <a class="doc" href="\(href)"><span class="ext" style="--h:\(hue(of: fileExtension(of: title)))">\(escape(fileExtension(of: title).prefix(4).uppercased()))</span>\
            <span><b dir="auto">\(escape(title))</b>\(size)</span></a>

            """
        }
    }

    /// A voice message or audio file: play and pause, the sender's waveform
    /// (or a bar) to seek in, its length, and a speed. The script makes it
    /// work; without it the browser's own player stands in.
    private static func player(href: String, seconds: UInt32?, waveform: [UInt8]) -> String {
        var wave = ""
        if waveform.isEmpty {
            wave = "<div class=\"wave bar\"><i></i></div>"
        } else {
            let peak = max(1, Int(waveform.max() ?? 1))
            wave = "<div class=\"wave\">" + waveform.map { "<i style=\"height:\(max(10, Int($0) * 100 / peak))%\"></i>" }.joined() + "</div>"
        }
        let length = escape(seconds.map(duration) ?? "")
        return """
        <div class="vp" data-src="\(href)" data-seconds="\(seconds ?? 0)"><button class="play" type="button" aria-label="\(escape(String(localized: "Play")))"></button>\(wave)<span class="time">\(length)</span><button class="rate" type="button" aria-label="\(escape(String(localized: "Speed")))">1×</button><noscript><audio controls preload="none" src="\(href)"></audio></noscript></div>

        """
    }

    /// What stands in for an attachment that is not in the folder.
    private static func omitted(_ kind: ChatExportMediaKind, name: String?) -> String {
        switch kind {
        case .photo: String(localized: "Photo, not included")
        case .video: String(localized: "Video, not included")
        case .voice: String(localized: "Voice message, not included")
        case .audio: String(localized: "Audio, not included")
        case .sticker: String(localized: "Sticker, not included")
        case .document: String(localized: "Document, not included") + (name.map { ": \($0)" } ?? "")
        }
    }

    private static func duration(_ seconds: UInt32) -> String {
        Duration.seconds(Int(seconds)).formatted(.time(pattern: .minuteSecond))
    }

    private static func fileExtension(of name: String) -> String {
        (name as NSString).pathExtension
    }

    // MARK: Pages

    private static func navigation(_ page: Page) -> String {
        guard page.pages > 1 else { return "" }
        var html = "<nav>"
        if page.number > 1 {
            html += "<a href=\"\(fileName(page: page.number - 1))\">← \(escape(String(localized: "Earlier")))</a>"
        }
        html += "<span>\(escape(String(localized: "Page \(page.number) of \(page.pages)")))</span>"
        if page.number < page.pages {
            html += "<a href=\"\(fileName(page: page.number + 1))\">\(escape(String(localized: "Later"))) →</a>"
        }
        return html + "</nav>\n"
    }

    // MARK: Text

    /// A message's text as HTML: the markup's styles, links to the web, and
    /// each line break kept.
    static func html(from text: AttributedString) -> String {
        var html = ""
        for run in text.runs {
            var piece = escape(String(text[run.range].characters)).replacingOccurrences(of: "\n", with: "<br>\n")
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { piece = "<code>\(piece)</code>" }
            if intent.contains(.stronglyEmphasized) { piece = "<strong>\(piece)</strong>" }
            if intent.contains(.emphasized) { piece = "<em>\(piece)</em>" }
            if intent.contains(.strikethrough) { piece = "<s>\(piece)</s>" }
            if let link = run.link, let href = safeLink(link) {
                piece = "<a href=\"\(escape(href))\">\(piece)</a>"
            }
            html += piece
        }
        return html
    }

    /// A link that goes to the web, a mail address or a phone: never a
    /// script or a file.
    static func safeLink(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme) else { return nil }
        return url.absoluteString
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    /// A path inside the folder as a link: each part percent-encoded.
    static func path(_ file: String) -> String {
        file.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
    }

    private static func anchor(_ id: String) -> String {
        String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(64).map(Character.init))
    }

    /// A hue from the name, the same every time, so each person keeps a colour.
    static func hue(of name: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Int(hash % 360)
    }

    // MARK: Style

    static let style = #"""
    :root{color-scheme:light dark;--bg:#e9edf0;--panel:#fff;--in:#fff;--out:#d9fdd3;--text:#111b21;--sub:#667781;--chip:rgba(17,27,33,.06);--line:rgba(17,27,33,.1);--link:#0a7cc2;--accent:#00a884}
    @media(prefers-color-scheme:dark){:root{--bg:#0b141a;--panel:#111b21;--in:#202c33;--out:#005c4b;--text:#e9edef;--sub:#8696a0;--chip:rgba(233,237,239,.09);--line:rgba(233,237,239,.12);--link:#53bdeb;--accent:#00a884}}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--text);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased}
    header{background:var(--panel);border-bottom:1px solid var(--line)}
    .top{max-width:860px;margin:0 auto;padding:14px 16px;display:flex;align-items:center;gap:14px}
    h1{margin:0;font-size:19px;line-height:1.2}header p{margin:3px 0 0;color:var(--sub);font-size:13px}
    .wrap{max-width:860px;margin:0 auto;padding:0 16px 48px}
    a{color:var(--link)}
    nav{display:flex;gap:18px;justify-content:center;align-items:center;padding:16px 0;font-size:14px;color:var(--sub)}
    nav a{text-decoration:none;font-weight:500}
    .av{flex:none;width:34px;height:34px;border-radius:50%;display:inline-flex;align-items:center;justify-content:center;font-size:13px;font-weight:600;color:#fff;background:hsl(var(--h) 45% 46%)}
    .av.big{width:44px;height:44px;font-size:16px}.av.gap{background:none}
    .day{position:sticky;top:8px;z-index:3;text-align:center;margin:22px 0 10px;pointer-events:none}
    .day span{display:inline-block;background:var(--panel);color:var(--sub);font-size:12.5px;font-weight:500;padding:4px 12px;border-radius:999px;box-shadow:0 1px 2px rgba(11,20,26,.15)}
    .row{display:flex;gap:8px;align-items:flex-start;margin-top:12px}.row.cont{margin-top:2px}
    .row.out{flex-direction:row-reverse}
    .bubble{position:relative;max-width:min(76%,620px);min-width:0;padding:6px 10px 5px;border-radius:12px;background:var(--in);box-shadow:0 1px 1px rgba(11,20,26,.13);overflow-wrap:anywhere}
    .out .bubble{background:var(--out)}
    .row:not(.cont) .bubble{border-top-left-radius:4px}.row.out:not(.cont) .bubble{border-top-left-radius:12px;border-top-right-radius:4px}
    .who{font-weight:600;font-size:13.5px;margin-bottom:1px;color:hsl(var(--h) 55% 36%)}
    @media(prefers-color-scheme:dark){.who{color:hsl(var(--h) 65% 70%)}}
    .fwd{color:var(--sub);font-size:12.5px;margin-bottom:2px}
    blockquote{margin:2px 0 5px;padding:4px 9px;border-left:3px solid hsl(var(--h) 55% 45%);background:var(--chip);border-radius:6px;font-size:13.5px;color:var(--sub);overflow:hidden;max-height:4.6em}
    blockquote b{display:block;font-size:13px;color:hsl(var(--h) 55% 36%)}
    @media(prefers-color-scheme:dark){blockquote b{color:hsl(var(--h) 65% 70%)}}
    .text code{font:13px ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--chip);padding:0 4px;border-radius:4px}
    .text ul{margin:4px 0 0;padding-left:18px}.text li{margin:1px 0}
    .media{display:block;max-width:100%}
    a.media{cursor:zoom-in}.media img,video.media{display:block;max-width:100%;max-height:440px;border-radius:8px;margin:2px 0}
    img.sticker{display:block;width:150px;max-width:100%}
    .doc{display:flex;align-items:center;gap:11px;padding:9px 11px;margin:2px 0;background:var(--chip);border-radius:10px;text-decoration:none;color:var(--text);min-width:230px}
    .doc b{display:block;font-weight:500}.doc small{display:block}
    .ext{flex:none;width:40px;height:40px;border-radius:9px;display:inline-flex;align-items:center;justify-content:center;font-size:11px;font-weight:700;color:#fff;background:hsl(var(--h) 50% 48%)}
    .vp{display:flex;align-items:center;gap:10px;min-width:280px;padding:3px 0}
    .vp .play{flex:none;width:36px;height:36px;border-radius:50%;border:0;background:var(--accent);color:#fff;cursor:pointer;display:inline-flex;align-items:center;justify-content:center;padding:0}
    .vp .play::before{content:"";display:block;margin-left:3px;border-left:11px solid currentColor;border-top:7px solid transparent;border-bottom:7px solid transparent}
    .vp.playing .play::before{margin:0;width:11px;height:13px;border-left:3.5px solid currentColor;border-right:3.5px solid currentColor;border-top:0;border-bottom:0}
    .wave{flex:1;display:flex;align-items:center;gap:2px;height:30px;cursor:pointer;min-width:120px}
    .wave i{flex:1;min-width:2px;border-radius:2px;background:var(--sub);opacity:.45}.wave i.on{background:var(--accent);opacity:1}
    .wave.bar{height:6px;border-radius:3px;background:var(--chip);display:block;overflow:hidden;align-self:center}
    .wave.bar i{display:block;height:100%;width:0;background:var(--accent);opacity:1;border-radius:3px}
    .vp .time{flex:none;font-size:12.5px;color:var(--sub);font-variant-numeric:tabular-nums;min-width:34px;text-align:right}
    .vp .rate{flex:none;border:0;border-radius:999px;background:var(--chip);color:var(--sub);font-size:11.5px;font-weight:600;padding:3px 8px;cursor:pointer}
    .vp audio{max-width:100%;height:34px}
    .omitted{color:var(--sub);font-style:italic;font-size:13.5px;padding:2px 0}
    .meta{text-align:right;color:var(--sub);font-size:11.5px;margin-top:1px;line-height:1.2}
    .reactions{margin-top:3px}.reactions span{display:inline-block;background:var(--chip);border-radius:11px;padding:0 7px;margin-right:3px;font-size:13px}
    small{color:var(--sub);font-size:12.5px}
    .lb{position:fixed;inset:0;z-index:50;background:rgba(0,0,0,.9);display:none;align-items:center;justify-content:center}.lb.open{display:flex}
    .lb img{max-width:92vw;max-height:88vh;border-radius:6px;box-shadow:0 8px 40px rgba(0,0,0,.5)}
    .lb button{position:absolute;border:0;background:rgba(255,255,255,.14);color:#fff;font-size:26px;width:46px;height:46px;border-radius:50%;cursor:pointer;line-height:1}
    .lb button:hover{background:rgba(255,255,255,.26)}
    .lb .x{top:16px;right:16px}.lb .p{left:16px;top:50%;margin-top:-23px}.lb .n{right:16px;top:50%;margin-top:-23px}
    .lb .c{position:absolute;bottom:16px;left:0;right:0;text-align:center;color:#ddd;font-size:13px}
    @media(max-width:560px){.bubble{max-width:calc(100% - 44px)}.vp{min-width:0}}
    """#

    // MARK: Script

    /// What makes the players play and the pictures open over the page. Plain
    /// script that reads the page's own markup and reaches nothing else.
    static let script = #"""
    (function(){
    var d=document,cur=null;
    function fmt(t){t=Math.max(0,Math.round(t));return Math.floor(t/60)+":"+("0"+t%60).slice(-2)}
    d.querySelectorAll(".vp").forEach(function(vp){
      var a=null,play=vp.querySelector(".play"),wave=vp.querySelector(".wave"),time=vp.querySelector(".time"),rate=vp.querySelector(".rate"),
          bars=wave.children,total=+vp.dataset.seconds||0,speeds=[1,1.5,2],si=0;
      function dur(){return a&&isFinite(a.duration)&&a.duration>0?a.duration:total}
      function show(){
        var f=dur()?a.currentTime/dur():0;
        if(wave.classList.contains("bar")){bars[0].style.width=f*100+"%"}
        else{for(var i=0;i<bars.length;i++){bars[i].classList.toggle("on",i<f*bars.length)}}
        time.textContent=fmt(a.paused&&a.currentTime===0?dur():a.currentTime);
      }
      function make(){
        if(a)return a;
        a=new Audio(vp.dataset.src);a.preload="metadata";a.playbackRate=speeds[si];
        a.addEventListener("timeupdate",show);
        a.addEventListener("ended",function(){vp.classList.remove("playing");a.currentTime=0;show()});
        a.addEventListener("error",function(){vp.classList.remove("playing");time.textContent="!"});
        return a;
      }
      play.addEventListener("click",function(){
        make();
        if(a.paused){if(cur&&cur!==a){cur.pause()}cur=a;a.play();vp.classList.add("playing");}
        else{a.pause();vp.classList.remove("playing");}
        a.onpause=function(){vp.classList.remove("playing")};
      });
      wave.addEventListener("click",function(e){
        make();var r=wave.getBoundingClientRect(),f=(e.clientX-r.left)/r.width;
        var go=function(){a.currentTime=Math.max(0,Math.min(1,f))*dur();show()};
        if(isFinite(a.duration)){go()}else{a.addEventListener("loadedmetadata",go,{once:true})}
      });
      rate.addEventListener("click",function(){
        si=(si+1)%speeds.length;rate.textContent=speeds[si]+"×";if(a){a.playbackRate=speeds[si]}
      });
    });
    var photos=[].slice.call(d.querySelectorAll("a[data-photo]")),at=0,box=null,img,count;
    function build(){
      box=d.createElement("div");box.className="lb";
      box.innerHTML='<img alt=""><button class="x" aria-label="Close">×</button><button class="p" aria-label="Previous">‹</button><button class="n" aria-label="Next">›</button><div class="c"></div>';
      img=box.querySelector("img");count=box.querySelector(".c");
      box.addEventListener("click",function(e){
        var t=e.target;
        if(t.classList.contains("p")){go(-1)}else if(t.classList.contains("n")){go(1)}
        else if(t!==img){close()}
      });
      d.body.appendChild(box);
    }
    function go(step){at=(at+step+photos.length)%photos.length;img.src=photos[at].getAttribute("href");count.textContent=(at+1)+" / "+photos.length}
    function close(){box.classList.remove("open")}
    photos.forEach(function(link,i){
      link.addEventListener("click",function(e){
        if(e.metaKey||e.ctrlKey||e.shiftKey)return;
        e.preventDefault();if(!box)build();at=i;go(0);box.classList.add("open");
      });
    });
    d.addEventListener("keydown",function(e){
      if(!box||!box.classList.contains("open"))return;
      if(e.key==="Escape"){close()}else if(e.key==="ArrowLeft"){go(-1)}else if(e.key==="ArrowRight"){go(1)}
    });
    })();
    """#
}
