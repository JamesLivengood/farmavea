# Wording and configuration for the on-site chat. Not an ActiveRecord model - one
# set of values, belonging in code rather than a table, kept in one place so the
# claim made in the widget cannot drift apart from the one made anywhere else.
class ChatSettings
  # IMPORTANT - read before editing.
  #
  # This states a US nursing licence as a fact. It must never imply a Mexican
  # qualification or an offer of clinical care in Mexico:
  #
  #   * Practising nursing in Mexico requires a cédula profesional issued by the
  #     SEP. A US RN licence is not one and is not automatically recognised, so
  #     presenting it as authority to advise Mexican patients would misrepresent it.
  #   * Hence the wording names where the licence is from, and the widget says
  #     plainly that it does not replace a medical consultation in Mexico.
  #   * Do NOT write "verificada", "certificada en México", or a bare "enfermera
  #     titulada". Someone deciding what to take, or at what dose, weighs how
  #     authoritative the answer looks - an overstated credential is the difference
  #     between a helpful reply and a harmful one.
  OPERATOR_DESCRIPTION = "una enfermera(o) registrada(o) con licencia en EE.UU., no en México.".freeze

  # Shown to a visitor after they send their first message, so nobody sits waiting
  # on an instant reply that is not coming.
  ACKNOWLEDGEMENT = "Mensaje enviado. Te responderemos en cuanto podamos.".freeze

  # Sits above the message box, before anyone types - not buried in a footer. A
  # disclaimer only does its job if it is read before the question is asked, and on
  # a site where people are choosing what to buy and take, that matters.
  DISCLAIMER_HEADING = "Esto no es asesoría médica.".freeze
  DISCLAIMER = <<~TEXT.squish.freeze
    Nada de lo que se diga en este chat sustituye el diagnóstico, la receta o el
    consejo de un médico o farmacéutico. Si tienes síntomas, dudas sobre tu
    tratamiento o una emergencia, acude a un profesional de la salud.
  TEXT
end
