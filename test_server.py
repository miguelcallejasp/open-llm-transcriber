import unittest

import numpy as np

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


class AudioSuffixTests(unittest.TestCase):
    def test_wav_from_dictation_hotkey(self) -> None:
        self.assertEqual(server._audio_suffix("audio/wav"), ".wav")
        self.assertEqual(server._audio_suffix("audio/x-wav; charset=binary"), ".wav")

    def test_browser_octet_stream_falls_back_to_webm(self) -> None:
        self.assertEqual(server._audio_suffix("application/octet-stream"), ".webm")
        self.assertEqual(server._audio_suffix(""), ".webm")


class SilenceAndHallucinationTests(unittest.TestCase):
    def test_quiet_room_noise_is_silent(self) -> None:
        noise = np.random.default_rng(0).normal(0, 0.01, 32000).astype(np.float32)  # ~ -40 dBFS
        self.assertTrue(server._is_silent(noise))

    def test_speech_level_audio_is_not_silent(self) -> None:
        tone = (0.2 * np.sin(np.linspace(0, 2000, 16000))).astype(np.float32)  # ~ -17 dBFS
        self.assertFalse(server._is_silent(tone))

    def test_pauses_do_not_hide_speech(self) -> None:
        # 1 s of speech-level tone followed by 4 s of near-silence: overall RMS
        # drops to roughly -31 dBFS, but the loud windows still read ~ -17.
        tone = 0.2 * np.sin(np.linspace(0, 2000, 16000))
        quiet = np.random.default_rng(1).normal(0, 0.001, 64000)
        audio = np.concatenate([tone, quiet]).astype(np.float32)
        self.assertFalse(server._is_silent(audio))
        self.assertGreater(server._speech_level_dbfs(audio), -20)

    def test_short_recording_does_not_crash(self) -> None:
        self.assertTrue(server._is_silent(np.zeros(500, dtype=np.float32)))

    def test_empty_audio_is_silent(self) -> None:
        self.assertTrue(server._is_silent(np.zeros(0, dtype=np.float32)))

    def test_stock_phrases_are_dropped(self) -> None:
        for junk in ["Thank you.", "Субтитры сделал DimaTorzok", "Subtitles by the Amara.org community", "..."]:
            self.assertTrue(server._looks_hallucinated(junk), junk)

    def test_real_dictation_is_kept(self) -> None:
        self.assertFalse(server._looks_hallucinated("Thank you for the update, I will review it tomorrow."))
        self.assertFalse(server._looks_hallucinated("Hello, this is a test."))


if __name__ == "__main__":
    unittest.main()