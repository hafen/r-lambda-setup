import handler
import unittest

class StatsHandlerTest(unittest.TestCase):
    def test_stats(self):
        x = [1]
        y = [2]
        results = handler.calculate_stats(x, y)
