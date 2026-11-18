#!/usr/bin/env bash
# Usage: payment-state.sh <repo-dir>
# `PaymentState` enum and two `match` statements that end in `case _:`. Prints `base=<sha>`.
source "$(dirname "$0")/../../fixture-lib.sh"
init_repo "$1"
allow_commits

put payment.py <<'PY'
from enum import Enum


class PaymentState(Enum):
    PENDING = "pending"
    PAID = "paid"
    FAILED = "failed"


def label(state):
    match state:
        case PaymentState.PENDING:
            return "Waiting for payment"
        case PaymentState.PAID:
            return "Paid"
        case _:
            return "Payment failed"


def color(state):
    match state:
        case PaymentState.PAID:
            return "green"
        case _:
            return "red"
PY

put test_payment.py <<'PY'
import unittest

from payment import PaymentState, color, label


class PaymentTest(unittest.TestCase):
    def test_label_of_each_state(self):
        self.assertEqual(label(PaymentState.PENDING), "Waiting for payment")
        self.assertEqual(label(PaymentState.PAID), "Paid")
        self.assertEqual(label(PaymentState.FAILED), "Payment failed")

    def test_color_of_each_state(self):
        self.assertEqual(color(PaymentState.PAID), "green")
        self.assertEqual(color(PaymentState.FAILED), "red")


if __name__ == "__main__":
    unittest.main()
PY
commit "Add payment states"
echo "base=$(git rev-parse HEAD)"
