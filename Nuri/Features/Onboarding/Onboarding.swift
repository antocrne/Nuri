import SwiftUI

/// First launch: a few choices, each applied live behind the card. Skippable at any step;
/// Settings → General can replay it.
struct OnboardingOverlay: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings
    @State private var workSpaceName = ""
    @State private var workColor: Pastel? = .sage

    private static let lastStep = 3

    var body: some View {
        let step = browser.onboardingStep ?? 0
        ZStack {
            Color.black.opacity(0.1).contentShape(Rectangle())
            VStack(alignment: .leading, spacing: 18) {
                content(step)
                Spacer(minLength: 0)
                footer(step)
            }
            .padding(26)
            .frame(width: 460, height: 400, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.hairline))
            .shadow(color: Theme.shadow, radius: 30, y: 12)
        }
        .foregroundStyle(Theme.text)
        .tint(settings.accent.color)
    }

    @ViewBuilder
    private func content(_ step: Int) -> some View {
        @Bindable var settings = settings
        @Bindable var language = LanguageStore.shared
        switch step {
        case 0:
            NuriWordmark(height: 36)
            Text(L("Un navigateur léger. Pas de compte, pas de pisteur, pas de bruit : juste le monde.",
                   "A light browser. No account, no trackers, no noise: just the world."))
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Picker(L("Langue", "Language"), selection: $language.choice) {
                ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
        case 1:
            heading(L("Son allure", "How it looks"), L("Tout s'applique en direct, derrière cette carte.", "Everything applies live, behind this card."))
            Picker(L("Thème", "Theme"), selection: $settings.theme) {
                ForEach(ThemeChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Couleur", "Color")).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                ColorChoices(selection: Binding(get: { settings.accent }, set: { settings.accent = $0 ?? .peach }))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Transparence", "Transparency")).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                Slider(value: $settings.transparency, in: 0...1)
            }
            Toggle(L("Halos de couleur doux", "Soft color glows"), isOn: $settings.softGlows)
        case 2:
            heading(L("Votre vie privée", "Your privacy"), L("Vous pourrez tout changer dans les Réglages.", "You can change all of it in Settings."))
            Toggle(L("Bloquer les publicités et les pisteurs", "Block ads and trackers"), isOn: $settings.adBlockEnabled)
            Picker(L("Moteur de recherche", "Search engine"), selection: $settings.searchEngine) {
                ForEach(SearchEngine.allCases.filter { $0 != .custom }) { Text($0.name).tag($0) }
            }
            .fixedSize()
            Toggle(L("Se tenir à jour tout seul", "Keep itself up to date"), isOn: $settings.checkForUpdates)
        default:
            heading(L("Des espaces à part", "Spaces apart"),
                    L("Travail, maison… Chaque espace garde ses onglets, ses connexions et son historique. Vous avez déjà « \(browser.spaces.first?.name ?? "") ». Un autre ?",
                      "Work, home… Each space keeps its own tabs, sign-ins and history. You already have “\(browser.spaces.first?.name ?? "")”. Another one?"))
            TextField(L("Nom d'un autre espace (facultatif)", "Name of another space (optional)"), text: $workSpaceName)
                .textFieldStyle(.roundedBorder)
            ColorChoices(selection: $workColor, allowsNone: true)
        }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 22, weight: .medium, design: .rounded))
            Text(detail).font(.system(size: 13)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footer(_ step: Int) -> some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0...Self.lastStep, id: \.self) { index in
                    Circle().fill(index == step ? AnyShapeStyle(settings.accent.color) : AnyShapeStyle(Theme.hairline)).frame(width: 6, height: 6)
                }
            }
            Spacer()
            if step < Self.lastStep {
                Button(L("Passer", "Skip")) { finish() }.buttonStyle(.plain).foregroundStyle(Theme.secondaryText)
            }
            Button {
                if step < Self.lastStep { withAnimation(Theme.quick) { browser.onboardingStep = step + 1 } } else { finish() }
            } label: {
                Text(step < Self.lastStep ? L("Continuer", "Continue") : L("C'est parti", "Let's go"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(settings.accent.color))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func finish() {
        let name = workSpaceName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            let current = browser.currentSpace
            browser.addSpace(name: name, color: workColor)
            browser.switchSpace(to: current)
        }
        settings.onboardingCompleted = true
        browser.onboardingStep = nil
    }
}
