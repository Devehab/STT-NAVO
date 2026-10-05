import Foundation

/// Made-up dictations, recordings, files and clipboard items for `--demo` (see `Paths.isDemo`),
/// so screenshots and demos never show anyone's real text. Nothing here comes from a person.
enum DemoData {
    // MARK: Entry points

    /// Empties the demo folder, so every demo opens on the same data with fresh dates.
    static func reset() {
        guard Paths.isDemo, Paths.dataDir != Paths.supportDir else { return }
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: Paths.dataDir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: item)
        }
    }

    static func fill(_ db: Database) {
        guard Paths.isDemo, Paths.dataDir != Paths.supportDir else { return }
        for sample in dictations {
            let id = UUID().uuidString
            let words = TextTools.wordCount(sample.text)
            let seconds = max(2, (Double(words) / 2.6).rounded())
            let audio = Paths.audioDir.appendingPathComponent("\(id).wav")
            writeSilence(seconds: seconds, to: audio)
            let arabic = sample.language == "ar"
            try? db.save(Dictation(
                id: id,
                createdAt: sample.when.date,
                duration: seconds,
                language: sample.language,
                rawText: sample.text,
                cleanText: sample.text,
                appName: sample.app,
                appBundleID: nil,
                wordCount: words,
                audioPath: audio.path,
                engine: (arabic ? SpeechEngine.audar : SpeechEngine.whisper).historyName + " (mlx)",
                cleanup: sample.polished ? CleanupMode.local.rawValue : nil,
                latencyMs: 380 + (words * 37) % 900,
                status: .ok,
                errorMessage: nil
            ))
        }
        for sample in sessions {
            let id = UUID().uuidString
            let audio = Paths.sessionDir(id).appendingPathComponent(sample.kind == .meeting ? "recording.wav" : sample.source)
            writeSilence(seconds: sample.seconds, to: audio)
            let part = sample.seconds / Double(max(1, sample.parts.count))
            let chunks = sample.parts.enumerated().map { index, text in
                SessionChunk(index: index, start: Double(index) * part, end: Double(index + 1) * part, text: text, error: nil)
            }
            let arabic = sample.language == "ar"
            try? db.saveSession(Session(
                id: id,
                kind: sample.kind,
                title: sample.title,
                createdAt: sample.when.date,
                duration: sample.seconds,
                source: sample.source,
                audioPath: audio.path,
                status: chunks.isEmpty ? .ready : .done,
                engine: chunks.isEmpty ? nil : (arabic ? SpeechEngine.audar : SpeechEngine.whisper).historyName + " (mlx)",
                language: sample.language,
                chunks: chunks,
                error: nil
            ))
        }
        for sample in clips {
            let id = UUID().uuidString
            try? db.saveClip(
                id: id,
                text: sample.text,
                hash: ClipboardStore.hash(sample.text),
                copiedAt: sample.when.date,
                appName: sample.app,
                appBundleID: nil,
                searchText: TextTools.searchKey(sample.text)
            )
            if sample.starred {
                try? db.setClipStarred(id: id, starred: true)
            }
        }
        for (index, word) in vocabulary.enumerated() {
            try? db.saveVocabulary(VocabularyItem(
                id: UUID().uuidString,
                term: word.term,
                replacement: word.replacement,
                createdAt: Date().addingTimeInterval(Double(-index) * 3600)
            ))
        }
    }

    // MARK: Shapes

    private enum When {
        /// So many minutes before now.
        case ago(Int)
        /// A time of day, so many days back.
        case day(Int, Int, Int)

        var date: Date {
            switch self {
            case .ago(let minutes):
                return Date().addingTimeInterval(Double(-minutes) * 60)
            case .day(let back, let hour, let minute):
                let calendar = Calendar.current
                let start = calendar.startOfDay(for: Date())
                let day = calendar.date(byAdding: .day, value: -back, to: start) ?? start
                return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
            }
        }
    }

    private struct DictationSample {
        let when: When
        let language: String
        let app: String
        let polished: Bool
        let text: String

        init(_ when: When, _ language: String, _ app: String, polished: Bool = false, _ text: String) {
            self.when = when
            self.language = language
            self.app = app
            self.polished = polished
            self.text = text
        }
    }

    private struct SessionSample {
        let kind: SessionKind
        let when: When
        let title: String
        /// mic, system or both for a meeting; the file name for an import.
        let source: String
        let language: String
        let seconds: Double
        let parts: [String]
    }

    private struct ClipSample {
        let when: When
        let app: String?
        let starred: Bool
        let text: String

        init(_ when: When, _ app: String?, starred: Bool = false, _ text: String) {
            self.when = when
            self.app = app
            self.starred = starred
            self.text = text
        }
    }

    /// A short silent WAV (8 kHz, 8 bit, mono), so the players and the Retry buttons have a file.
    private static func writeSilence(seconds: Double, to url: URL) {
        let rate: UInt32 = 8000
        let count = UInt32(max(1, seconds) * Double(rate))
        var data = Data(capacity: 44 + Int(count))
        func add32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func add16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        add32(36 + count)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        add32(16) // size of the format block
        add16(1) // PCM
        add16(1) // mono
        add32(rate)
        add32(rate) // bytes a second
        add16(1) // bytes a sample
        add16(8) // bits a sample
        data.append(contentsOf: Array("data".utf8))
        add32(count)
        data.append(Data(repeating: 0x80, count: Int(count)))
        try? data.write(to: url)
    }

    // MARK: Dictations

    private static let dictations: [DictationSample] = [
        DictationSample(.ago(6), "en", "Mail", polished: true,
            "Hi Sara, thanks for sending the draft. I read it this morning and I think the second section is the strongest part. Could we move the pricing table up, right after the introduction? I can review the next version on Thursday."),
        DictationSample(.ago(21), "ar", "WhatsApp",
            "مرحبا سامر، خلصت مراجعة العرض وبعتلك الملاحظات على الإيميل. إذا عندك وقت بكرا الصبح منحكي عشر دقايق قبل الاجتماع."),
        DictationSample(.ago(48), "en", "Xcode",
            "Add a retry with exponential backoff to the upload task, and log the status code when the request fails."),
        DictationSample(.ago(95), "ar", "Slack",
            "يا شباب، الـ build الجديد جاهز على الـ staging، جربوه وخبروني إذا في أي bug قبل ما نعمل release."),
        DictationSample(.ago(170), "en", "Notes",
            "Ideas for the weekend trip: leave early on Saturday, stop at the lake for breakfast, then take the coast road. Remember to pack the camera, the small tripod and an extra battery."),

        DictationSample(.day(1, 18, 40), "ar", "Notes", polished: true,
            "أفكار للمقال الجديد: كيف يغير الإملاء الصوتي طريقة الكتابة اليومية، ولماذا الخصوصية مهمة عندما يعمل كل شيء على الجهاز نفسه."),
        DictationSample(.day(1, 15, 12), "en", "Notion",
            "Action items from today: Omar updates the onboarding checklist, Lina books the room for Monday, and I send the summary to the whole team before five."),
        DictationSample(.day(1, 11, 5), "ar", "Mail", polished: true,
            "السيدة ريم المحترمة، أشكرك على ردك السريع. أرفقت لك النسخة المحدثة من الجدول، وأرجو تأكيد الموعد النهائي قبل نهاية الأسبوع."),
        DictationSample(.day(1, 9, 31), "en", "Messages",
            "Running ten minutes late, save me a seat near the window."),

        DictationSample(.day(2, 20, 15), "ar", "Messages",
            "أنا بالطريق، بوصل بعد ربع ساعة تقريبا."),
        DictationSample(.day(2, 16, 48), "en", "Pages",
            "The museum opened in 1962 and was renovated twice. Today it holds more than four thousand pieces, most of them donated by local families."),
        DictationSample(.day(2, 13, 20), "ar", "Notion",
            "ملخص اليوم: أنهينا تصميم الصفحة الرئيسية، وبقي علينا اختبار نموذج التسجيل وكتابة نصوص الترحيب."),
        DictationSample(.day(2, 10, 2), "en", "Safari",
            "best lightweight hiking boots for wide feet"),

        DictationSample(.day(3, 17, 30), "en", "Mail", polished: true,
            "Dear Mr. Haddad, I am writing to confirm our meeting on Tuesday at ten in the morning. Please let me know if the time still works for you."),
        DictationSample(.day(3, 14, 9), "ar", "Pages",
            "تأسست المكتبة العامة في المدينة قبل ستين عاما، وهي اليوم تضم أكثر من مئة ألف كتاب وتستقبل مئات الزوار كل يوم."),
        DictationSample(.day(3, 9, 50), "ar", "Notes",
            "قائمة المشتريات: بندورة، خيار، زيت زيتون، خبز، لبن، نعنع، ليمون، وقهوة."),

        DictationSample(.day(4, 19, 22), "en", "Notes",
            "Grocery list: tomatoes, cucumbers, olive oil, bread, yogurt, mint, lemons and a bag of coffee beans."),
        DictationSample(.day(4, 12, 44), "ar", "Safari",
            "أفضل مطاعم المأكولات البحرية القريبة مني"),
        DictationSample(.day(4, 8, 58), "en", "Slack",
            "Good morning team, the new build is on staging. Please try the search page and tell me if anything looks off before we ship."),

        DictationSample(.day(5, 21, 3), "en", "Messages",
            "Happy birthday! I hope this year brings you everything you wished for."),
        DictationSample(.day(5, 15, 37), "ar", "Mail",
            "مرحبا فريق الدعم، لم يصلني رقم الطلب بعد إتمام الشراء أمس. هل يمكنكم إرساله مرة أخرى؟ شكرا لمساعدتكم."),
        DictationSample(.day(5, 10, 16), "ar", "Calendar",
            "حجز طاولة لأربعة أشخاص يوم الجمعة الساعة ثمانية مساء."),

        DictationSample(.day(6, 18, 5), "ar", "WhatsApp",
            "كل عام وأنت بخير، إن شاء الله سنة حلوة عليك وعلى العيلة."),
        DictationSample(.day(6, 11, 28), "en", "Calendar",
            "Team lunch next Wednesday at half past twelve."),
    ]

    // MARK: Meetings and files

    private static let sessions: [SessionSample] = [
        SessionSample(kind: .meeting, when: .ago(140), title: "Weekly product sync", source: MeetingSource.both.rawValue, language: "en", seconds: 372, parts: [
            "Good morning everyone, let's get started. Three things on the list today: the release date, the feedback from the beta group, and the plan for the new onboarding.",
            "On the release, we are on track for the fourteenth. The last two bugs were closed yesterday, and the only open item is the update to the help pages.",
            "The beta group sent forty two replies. Most people like the new search, and a few asked for a way to export their notes as plain text.",
            "Export should be simple. Omar thinks it is two days of work, so we can fit it in before the release without moving the date.",
            "For onboarding, Lina shared a first sketch. The idea is three short screens, each with one action, instead of the long tour we have now.",
            "I like that it is shorter. Can we test it with five new users next week and compare how many finish the setup?",
            "Yes, I will set up the test for Tuesday and share the numbers on Thursday. We also need new screenshots for the store page.",
            "Great. To sum up: release on the fourteenth, export added this week, onboarding test on Tuesday. Thanks everyone, see you next week.",
        ]),
        SessionSample(kind: .meeting, when: .day(1, 11, 30), title: "اجتماع فريق التسويق", source: MeetingSource.both.rawValue, language: "ar", seconds: 268, parts: [
            "صباح الخير جميعا. اليوم سنراجع نتائج حملة الشهر الماضي ونتفق على خطة الشهر القادم.",
            "الحملة وصلت إلى مئة وعشرين ألف شخص، وعدد الزيارات للموقع زاد بنسبة ثلاثين بالمئة مقارنة بالشهر الذي قبله.",
            "أفضل نتيجة كانت من الفيديوهات القصيرة، أما الإعلانات المصورة فكان أداؤها أقل من المتوقع.",
            "أقترح أن نزيد عدد الفيديوهات إلى ثلاثة في الأسبوع، وأن نجرب عنوانين مختلفين لكل فيديو لنعرف أيهما أفضل.",
            "موافقة. ريم ستجهز جدول النشر، وسامر يكتب النصوص، وأنا أتابع الميزانية مع الإدارة.",
            "ممتاز. نلتقي يوم الأحد القادم لمراجعة أول النتائج. شكرا لكم جميعا.",
        ]),
        SessionSample(kind: .meeting, when: .day(3, 15, 0), title: "Call with the design agency", source: MeetingSource.system.rawValue, language: "en", seconds: 195, parts: [
            "Thanks for joining. We looked at the three logo directions you sent, and the team keeps coming back to the second one.",
            "Good to hear. The second direction also works best at small sizes, which matters for the app icon and the menu bar.",
            "Could you try it with a warmer color, and send a version on a dark background as well?",
            "Of course. You will have both by Friday, together with the font files and a short usage guide.",
        ]),

        SessionSample(kind: .file, when: .ago(200), title: "New Recording 12", source: "New Recording 12.wav", language: "en", seconds: 47, parts: []),
        SessionSample(kind: .file, when: .ago(260), title: "Interview, urban gardening", source: "Interview, urban gardening.wav", language: "en", seconds: 301, parts: [
            "Today I am talking with a gardener who turned the roof of her building into a shared vegetable garden. How did it start?",
            "It started with four pots of tomatoes. The neighbors saw them, asked questions, and by the next spring we had twenty people involved.",
            "What grows best on a roof in a hot city?",
            "Herbs are the easiest: mint, basil and thyme. Peppers and cherry tomatoes do well too, as long as you water early in the morning.",
            "And what would you tell someone who wants to begin? Start small, pick one plant you love to eat, and learn from it for a season.",
        ]),
        SessionSample(kind: .file, when: .day(1, 16, 20), title: "محاضرة، مقدمة في علم الفلك", source: "محاضرة، مقدمة في علم الفلك.wav", language: "ar", seconds: 244, parts: [
            "أهلا بكم في المحاضرة الأولى من مقدمة في علم الفلك. سنبدأ اليوم بسؤال بسيط: ماذا نرى عندما ننظر إلى السماء ليلا؟",
            "معظم النقاط المضيئة التي نراها هي نجوم تشبه شمسنا، لكنها بعيدة جدا، وضوؤها يحتاج إلى سنوات طويلة ليصل إلينا.",
            "الكواكب تختلف عن النجوم لأنها لا تصدر ضوءا من نفسها، بل تعكس ضوء الشمس، ولهذا يبدو ضوؤها ثابتا لا يتلألأ.",
            "مجموعتنا الشمسية تضم ثمانية كواكب، أقربها إلى الشمس عطارد وأبعدها نبتون، والأرض هي الثالثة في الترتيب.",
            "في المحاضرة القادمة سنتحدث عن القمر وأطواره، وعن سبب حدوث الكسوف والخسوف.",
        ]),
        SessionSample(kind: .file, when: .day(2, 9, 10), title: "Podcast clip, the history of coffee", source: "Podcast clip, the history of coffee.wav", language: "en", seconds: 136, parts: [
            "Coffee was first brewed as a drink in Yemen in the fifteenth century, and from the port of Mocha it traveled across the region.",
            "Coffee houses soon became places to talk, play chess and hear the news, long before newspapers were common.",
            "By the seventeenth century it had reached Europe, where the first cafes opened in Venice, London and Paris.",
        ]),
        SessionSample(kind: .file, when: .day(4, 18, 45), title: "Voice memo, book notes", source: "Voice memo, book notes.wav", language: "en", seconds: 82, parts: [
            "Notes on chapter three. The main idea is that habits are built by making the first step tiny, so small that it feels almost too easy.",
            "The example I liked: instead of planning to read every night, put the book on the pillow in the morning. Try this for a week.",
        ]),
    ]

    // MARK: Clipboard

    private static let clips: [ClipSample] = [
        ClipSample(.ago(3), "Safari", "https://github.com/ml-explore/mlx"),
        ClipSample(.ago(9), nil, "Flight NV 204, gate 12, boarding at 18:45"),
        ClipSample(.ago(17), "Xcode", "func greet(_ name: String) -> String {\n    \"Hello, \\(name)!\"\n}"),
        ClipSample(.ago(26), "WhatsApp", starred: true, "شارع النخيل 24، الطابق الثاني، بجانب المكتبة العامة"),
        ClipSample(.ago(41), "Mail", "Order number 48213, arriving on Tuesday"),
        ClipSample(.ago(58), "Terminal", "npm install && npm run dev"),
        ClipSample(.ago(75), "Notes", "ما أجمل أن تكتب بصوتك، والكلمات تظهر حيث تريد."),
        ClipSample(.ago(110), "Calendar", "Meeting room B, third floor, Thursday at 10:30"),
        ClipSample(.ago(150), "Figma", starred: true, "#1F6FEB"),
        ClipSample(.ago(190), "TablePlus", "SELECT name, email FROM users WHERE active = 1 ORDER BY name;"),
        ClipSample(.ago(240), "Mail", "hello@example.com"),
        ClipSample(.day(1, 17, 5), "Reminders", "Water the plants on Sunday"),
        ClipSample(.day(1, 12, 40), "Terminal", "git commit -m \"Fix the upload retry\""),
        ClipSample(.day(1, 9, 15), nil, "رمز الخصم للطلب القادم: WELCOME10"),
        ClipSample(.day(2, 14, 30), "Pages", "The museum opened in 1962 and was renovated twice."),
        ClipSample(.day(2, 10, 0), "Contacts", "+1 (555) 010 0199"),
    ]

    // MARK: Dictionary

    private static let vocabulary: [(term: String, replacement: String?)] = [
        ("Navo", nil),
        ("MLX", nil),
        ("SwiftUI", nil),
        ("cube control", "kubectl"),
        ("my work email", "hello@example.com"),
    ]
}
