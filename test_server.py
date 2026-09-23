import unittest

import server


class TranscribeOptionsTests(unittest.TestCase):
    def test_auto_language_enables_silence_hallucination_filter(self) -> None:
        options = server._transcribe_options("auto")

        self.assertFalse(options["fp16"])
        self.assertTrue(options["word_timestamps"])
        self.assertEqual(
            options["hallucination_silence_threshold"],
            server.HALLUCINATION_SILENCE_THRESHOLD,
        )
        self.assertNotIn("language", options)

    def test_explicit_language_is_forwarded(self) -> None:
        options = server._transcribe_options("es")

        self.assertEqual(options["language"], "es")


if __name__ == "__main__":
    unittest.main()