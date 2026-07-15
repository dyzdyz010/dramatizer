defmodule DramatizerWeb.Live.Components.ProviderStatus do
  use DramatizerWeb, :html

  attr :mode, :atom, required: true
  attr :credential_available, :boolean, required: true
  attr :text_model, :string, required: true
  attr :image_model, :string, required: true

  def provider_status(assigns) do
    ~H"""
    <section class="provider-status" data-provider-mode={@mode} aria-label="当前运行模式">
      <span class={[@mode == :openai && "provider-live", @mode == :fake && "provider-fake"]}>
        <i></i>
        {if @mode == :openai, do: "OpenAI 已启用", else: "Fake 模拟模式"}
      </span>
      <span class="provider-models">{@text_model} · {@image_model}</span>
      <span class={[
        @credential_available && "credential-ready",
        !@credential_available && "credential-missing"
      ]}>
        {if @credential_available, do: "凭据可用", else: "凭据不可用"}
      </span>
    </section>
    """
  end
end
