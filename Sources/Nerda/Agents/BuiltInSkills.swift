/// The Site skills Nerda ships, written as the owner's files are. An owner's
/// skill of the same name takes the place of one; the rest are written for
/// the owner's sites as they are needed, by the owner or saved by agents.
nonisolated extension SiteSkill {
    static let builtIn: [SiteSkill] = [github].compactMap { SiteSkill(file: $0, named: "", isBuiltIn: true) }

    private static let github = """
        ---
        name: github
        description: Reading repositories, files, issues and pull requests on GitHub
        sites: github.com, gist.github.com
        ---

        - A file's text: fetch `https://github.com/<owner>/<repo>/raw/<branch>/<path>` rather than \
        opening its page; the fetch carries the user's sign-in, so private repositories they can see work too.
        - A pull request's or commit's changes as one text: fetch its address with `.diff` added, such as \
        `https://github.com/<owner>/<repo>/pull/12.diff` (or `.patch`, with the commit messages).
        - Issues and pull requests are searched in the address: \
        `https://github.com/<owner>/<repo>/issues?q=is:open+label:bug`; `is:pr`, `author:`, `sort:updated-desc` \
        go there too.
        - `api.github.com` answers JSON, but the user's sign-in doesn't reach it: without a token it sees \
        public repositories only, about 60 requests an hour. Prefer the pages, or `fetch` on github.com.
        - Pages fill in after they load: when a snapshot looks thin, take it again a moment later.
        - Comment, review, merge, close or star only when the user asked for that: each acts as them, \
        in public view of others.
        """
}
