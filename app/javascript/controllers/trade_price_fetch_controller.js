import { Controller } from "@hotwired/stimulus";

// Fetches the historical closing price for a trade's security on its date,
// then populates the price input so the user can review and auto-save.
export default class extends Controller {
  static values = { url: String };
  static targets = ["price", "button"];

  async fetch(event) {
    event.preventDefault();
    this.buttonTarget.disabled = true;

    try {
      const response = await window.fetch(this.urlValue, {
        headers: {
          Accept: "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content
        }
      });

      if (!response.ok) throw new Error("not_found");

      const { price } = await response.json();
      this.priceTarget.value = price;
      this.priceTarget.dispatchEvent(new Event("change", { bubbles: true }));
    } catch (_e) {
      // Price unavailable — leave field as-is
    } finally {
      this.buttonTarget.disabled = false;
    }
  }
}
