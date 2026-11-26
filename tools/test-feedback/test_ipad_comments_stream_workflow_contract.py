"""Source-only safety checks for genuine iPad Comments lifecycle logging.

These checks only inspect the committed GitHub Actions workflow. They never
inject a game, account, HTTP response, XCTest UI, synthetic OSLog or screenshot.
Native execution and original screenshots remain mandatory independently.
"""
from pathlib import Path
import unittest


WORKFLOW = (
    Path(__file__).resolve().parents[2]
    / ".github"
    / "workflows"
    / "ios.yml"
)


class IPadCommentsStreamWorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")
        cls.job = cls.workflow.split(
            "      - name: Run iPad feed UI evaluator\n", 1
        )[1].split(
            "      - name: Build iPad UI test-feedback artifact\n", 1
        )[0]

    def test_real_simulator_stream_starts_before_strict_xctest(self):
        stream = 'xcrun simctl spawn "${{ steps.ipad.outputs.udid }}" log stream'
        test = "xcodebuild test -project Hephaestus.xcodeproj -scheme Hephaestus"
        self.assertIn(stream, self.job)
        self.assertIn(test, self.job)
        self.assertLess(self.job.index(stream), self.job.index(test))
        self.assertIn("set -o pipefail", self.job)
        self.assertIn("CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ipad-feed-ui.log || {", self.job)
        self.assertIn("exit 1", self.job)

    def test_stream_only_includes_privacy_scoped_comments_category(self):
        self.assertIn(
            """--predicate 'subsystem == "ai.tinydream.Hephaestus" AND category == "ArcadePulseComments"'""",
            self.job,
        )
        self.assertIn("--level info --style compact", self.job)
        self.assertIn(
            "> /tmp/ipad-comments-presenter-stream.log 2>&1 &",
            self.job,
        )
        self.assertNotIn("log stream --style", self.job)

    def test_exit_trap_always_reaps_stream_and_keeps_artifacts(self):
        for required in (
            "comments_stream_pid=$!",
            "kill \"$comments_stream_pid\" 2>/dev/null || true",
            "wait \"$comments_stream_pid\" 2>/dev/null || true",
            "trap stop_comments_stream EXIT",
            "/tmp/ipad-comments-presenter-stream.log",
            "/tmp/ipad-comments-presenter.log",
            "/tmp/ipad-feed-ui.xcresult",
        ):
            with self.subTest(required=required):
                self.assertIn(required, self.workflow)
        self.assertIn(
            "      - name: Capture native iPad Comments presenter signals\n",
            self.workflow,
        )


    def test_grid_comments_has_one_native_press_owner_and_inert_decorations(self):
        card = (WORKFLOW.parents[2] / "Hephaestus" / "Views" / "Discover"
                / "GameFeedCard.swift").read_text(encoding="utf-8")
        style = card.split("private struct GridCommentsPressStyle: ButtonStyle", 1)[1].split(
            "/// A game-first social card.", 1)[0]
        comments = card.split("Button(action: onOpenComments)", 1)[1].split("Menu {", 1)[0]
        self.assertIn(".onChange(of: configuration.isPressed)", style)
        self.assertIn("#if DEBUG", style)
        self.assertIn("UI_GRID_COMMENTS_PRESS_ACTIVE=", style)
        self.assertIn("privacy: .public", style)
        self.assertNotIn("TapGesture", style)
        self.assertNotIn("onOpenComments", style)
        self.assertIn(".buttonStyle(GridCommentsPressStyle())", comments)
        self.assertIn(".contentShape(Rectangle())", comments)
        self.assertIn("GameFeedCardSocialActionLayout.minimumHitSize", comments)
        self.assertNotIn("Gesture(", comments)
        stage = card.split("ZStack(alignment: .bottomLeading)", 1)[1].split(
            "VStack(alignment: .leading, spacing: 7)", 1)[0]
        self.assertEqual(stage.count(".allowsHitTesting(false)"), 3)
        border = card.split(".stroke(Color.primary.opacity(0.06), lineWidth: 1)", 1)[1].split(
            ".shadow(", 1)[0]
        self.assertIn(".allowsHitTesting(false)", border)
        self.assertIn(".accessibilityHidden(true)", border)


if __name__ == "__main__":
    unittest.main()
