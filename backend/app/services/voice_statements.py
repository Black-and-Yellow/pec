"""Fixed spoken statements, one per verdict per language.

Every sentence here is written by hand and never generated at request time.
That is deliberate. The spoken verdict must be the same claim the screen
already made, and a translation model asked to phrase a fraud warning on the
fly can soften it, sharpen it, or invent a reason the engine never found. A
person who cannot read the screen has no way to notice that drift, so the one
channel they can check is the one that must not be improvised.

Only the score is substituted. The wording around it is frozen, which means a
statement can be reviewed once by someone who speaks the language and then
trusted for every payment it ever describes.

Each statement mirrors, in order:
  * the screen headline  (_ResultHeader in risk_result_screen.dart)
  * the numeric score    (_ScoreSummary)
  * the recommended action (RiskEngine._recommendation)

CORRECTIONS ARE ONE LINE EACH. If a native speaker reads one of these and
finds it stilted or wrong, edit that single string. Keep the {score}
placeholder and keep the meaning of the English source, which is quoted above
each language block.
"""

from __future__ import annotations

from collections.abc import Mapping
from types import MappingProxyType
from typing import Final

from app.schemas import RiskLevel

#: Languages offered to the listener, in the order the app shows them.
#: The key is what the API accepts; the label is what the button displays.
SUPPORTED_LANGUAGES: Final[Mapping[str, str]] = MappingProxyType(
    {
        "hi": "हिंदी",
        "ta": "தமிழ்",
        "te": "తెలుగు",
        "kn": "ಕನ್ನಡ",
        "ml": "മലയാളം",
    }
)

# English source of each verdict, kept beside the translations so a reviewer
# can check a claim without reading the Dart and Python it came from.
#
# SAFE     "No strong warning signal found. Risk score {score} out of 100.
#           Verify the recipient details, then continue in your usual UPI app
#           if they are correct."
# CAUTION  "Pause and verify the recipient. Risk score {score} out of 100.
#           Check the recipient independently and review the amount before
#           deliberately continuing."
# HIGH     "Strong warning signals found. Risk score {score} out of 100. Stop
#           the UPI handoff and verify the recipient independently. Prepare
#           recovery actions if you already paid."

_STATEMENTS: Final[Mapping[RiskLevel, Mapping[str, str]]] = MappingProxyType(
    {
        RiskLevel.SAFE: MappingProxyType(
            {
                "hi": (
                    "कोई गंभीर चेतावनी संकेत नहीं मिला। जोखिम अंक सौ में से {score}। "
                    "पैसे भेजने से पहले पाने वाले का नाम और विवरण जाँच लें, और सही होने पर "
                    "अपने सामान्य यूपीआई ऐप में आगे बढ़ें।"
                ),
                "ta": (
                    "வலுவான எச்சரிக்கை அறிகுறி எதுவும் இல்லை. ஆபத்து மதிப்பெண் நூற்றுக்கு "
                    "{score}. பணம் அனுப்பும் முன் பெறுநரின் பெயரையும் விவரங்களையும் "
                    "சரிபார்த்து, சரியாக இருந்தால் உங்கள் வழக்கமான யுபிஐ செயலியில் தொடரவும்."
                ),
                "te": (
                    "బలమైన హెచ్చరిక సంకేతం ఏదీ కనిపించలేదు. ప్రమాద స్కోరు వందకు {score}. "
                    "డబ్బు పంపే ముందు స్వీకర్త పేరును, వివరాలను సరిచూసుకోండి, సరిగ్గా ఉంటే "
                    "మీ సాధారణ యూపీఐ యాప్‌లో కొనసాగండి."
                ),
                "kn": (
                    "ಪ್ರಬಲ ಎಚ್ಚರಿಕೆಯ ಸೂಚನೆ ಯಾವುದೂ ಕಂಡುಬಂದಿಲ್ಲ. ಅಪಾಯದ ಅಂಕ ನೂರಕ್ಕೆ {score}. "
                    "ಹಣ ಕಳುಹಿಸುವ ಮೊದಲು ಸ್ವೀಕರಿಸುವವರ ಹೆಸರು ಮತ್ತು ವಿವರಗಳನ್ನು ಪರಿಶೀಲಿಸಿ, ಸರಿಯಿದ್ದರೆ "
                    "ನಿಮ್ಮ ಎಂದಿನ ಯುಪಿಐ ಆ್ಯಪ್‌ನಲ್ಲಿ ಮುಂದುವರಿಯಿರಿ."
                ),
                "ml": (
                    "ശക്തമായ മുന്നറിയിപ്പ് സൂചനകളൊന്നും കണ്ടെത്തിയില്ല. അപകട സ്കോർ നൂറിൽ "
                    "{score}. പണം അയയ്ക്കുന്നതിന് മുൻപ് സ്വീകർത്താവിന്റെ പേരും വിവരങ്ങളും "
                    "പരിശോധിക്കുക, ശരിയാണെങ്കിൽ നിങ്ങളുടെ പതിവ് യുപിഐ ആപ്പിൽ തുടരുക."
                ),
            }
        ),
        RiskLevel.CAUTION: MappingProxyType(
            {
                "hi": (
                    "रुकिए और पाने वाले की जाँच कीजिए। जोखिम अंक सौ में से {score}। "
                    "पाने वाले को किसी अलग और भरोसेमंद तरीके से जाँचें, रकम दोबारा देखें, "
                    "और तभी सोच-समझकर आगे बढ़ें।"
                ),
                "ta": (
                    "நிறுத்தி, பெறுநரைச் சரிபாருங்கள். ஆபத்து மதிப்பெண் நூற்றுக்கு {score}. "
                    "நீங்கள் ஏற்கனவே நம்பும் வேறு ஒரு வழியில் பெறுநரைச் சரிபாருங்கள், "
                    "தொகையை மீண்டும் பாருங்கள், பிறகுதான் யோசித்துத் தொடருங்கள்."
                ),
                "te": (
                    "ఆగండి, స్వీకర్తను సరిచూసుకోండి. ప్రమాద స్కోరు వందకు {score}. "
                    "మీరు ఇప్పటికే నమ్మే వేరే మార్గంలో స్వీకర్తను నిర్ధారించుకోండి, మొత్తాన్ని "
                    "మళ్ళీ చూడండి, ఆ తర్వాతే ఆలోచించి కొనసాగండి."
                ),
                "kn": (
                    "ನಿಲ್ಲಿಸಿ, ಸ್ವೀಕರಿಸುವವರನ್ನು ಪರಿಶೀಲಿಸಿ. ಅಪಾಯದ ಅಂಕ ನೂರಕ್ಕೆ {score}. "
                    "ನೀವು ಈಗಾಗಲೇ ನಂಬುವ ಬೇರೊಂದು ಮಾರ್ಗದಲ್ಲಿ ಸ್ವೀಕರಿಸುವವರನ್ನು ಖಚಿತಪಡಿಸಿಕೊಳ್ಳಿ, "
                    "ಮೊತ್ತವನ್ನು ಮತ್ತೊಮ್ಮೆ ನೋಡಿ, ಆಮೇಲೆ ಯೋಚಿಸಿ ಮುಂದುವರಿಯಿರಿ."
                ),
                "ml": (
                    "നിർത്തുക, സ്വീകർത്താവിനെ പരിശോധിക്കുക. അപകട സ്കോർ നൂറിൽ {score}. "
                    "നിങ്ങൾ ഇതിനകം വിശ്വസിക്കുന്ന മറ്റൊരു വഴിയിലൂടെ സ്വീകർത്താവിനെ "
                    "ഉറപ്പാക്കുക, തുക വീണ്ടും പരിശോധിക്കുക, എന്നിട്ട് മാത്രം ആലോചിച്ച് തുടരുക."
                ),
            }
        ),
        RiskLevel.HIGH: MappingProxyType(
            {
                "hi": (
                    "गंभीर चेतावनी संकेत मिले हैं। जोखिम अंक सौ में से {score}। "
                    "यूपीआई भुगतान अभी रोक दीजिए और पाने वाले की जाँच किसी अलग भरोसेमंद "
                    "तरीके से कीजिए। अगर आपने पहले ही पैसे भेज दिए हैं, तो तुरंत शिकायत "
                    "और वापसी की कार्रवाई शुरू कीजिए।"
                ),
                "ta": (
                    "வலுவான எச்சரிக்கை அறிகுறிகள் கண்டறியப்பட்டுள்ளன. ஆபத்து மதிப்பெண் "
                    "நூற்றுக்கு {score}. யுபிஐ பணப்பரிமாற்றத்தை இப்போதே நிறுத்துங்கள், "
                    "பெறுநரை நீங்கள் நம்பும் வேறு வழியில் சரிபாருங்கள். ஏற்கனவே பணம் "
                    "அனுப்பியிருந்தால், உடனே புகார் அளித்து மீட்பு நடவடிக்கைகளைத் தொடங்குங்கள்."
                ),
                "te": (
                    "బలమైన హెచ్చరిక సంకేతాలు కనిపించాయి. ప్రమాద స్కోరు వందకు {score}. "
                    "యూపీఐ చెల్లింపును ఇప్పుడే ఆపండి, స్వీకర్తను మీరు నమ్మే వేరే మార్గంలో "
                    "నిర్ధారించుకోండి. ఇప్పటికే డబ్బు పంపి ఉంటే, వెంటనే ఫిర్యాదు చేసి "
                    "రికవరీ చర్యలు ప్రారంభించండి."
                ),
                "kn": (
                    "ಪ್ರಬಲ ಎಚ್ಚರಿಕೆಯ ಸೂಚನೆಗಳು ಕಂಡುಬಂದಿವೆ. ಅಪಾಯದ ಅಂಕ ನೂರಕ್ಕೆ {score}. "
                    "ಯುಪಿಐ ಪಾವತಿಯನ್ನು ಈಗಲೇ ನಿಲ್ಲಿಸಿ, ಸ್ವೀಕರಿಸುವವರನ್ನು ನೀವು ನಂಬುವ ಬೇರೊಂದು "
                    "ಮಾರ್ಗದಲ್ಲಿ ಖಚಿತಪಡಿಸಿಕೊಳ್ಳಿ. ಈಗಾಗಲೇ ಹಣ ಕಳುಹಿಸಿದ್ದರೆ, ತಕ್ಷಣ ದೂರು ನೀಡಿ "
                    "ಮರುಪಡೆಯುವ ಕ್ರಮಗಳನ್ನು ಆರಂಭಿಸಿ."
                ),
                "ml": (
                    "ശക്തമായ മുന്നറിയിപ്പ് സൂചനകൾ കണ്ടെത്തി. അപകട സ്കോർ നൂറിൽ {score}. "
                    "യുപിഐ പണമിടപാട് ഇപ്പോൾ തന്നെ നിർത്തുക, സ്വീകർത്താവിനെ നിങ്ങൾ "
                    "വിശ്വസിക്കുന്ന മറ്റൊരു വഴിയിലൂടെ ഉറപ്പാക്കുക. ഇതിനകം പണം "
                    "അയച്ചിട്ടുണ്ടെങ്കിൽ, ഉടൻ പരാതി നൽകി തിരിച്ചുപിടിക്കാനുള്ള നടപടികൾ തുടങ്ങുക."
                ),
            }
        ),
    }
)


def is_supported_language(language: str) -> bool:
    return language in SUPPORTED_LANGUAGES


def statement_for(*, level: RiskLevel, score: int, language: str) -> str:
    """Return the spoken sentence for a verdict already reached.

    The caller supplies the engine's own level and score; nothing here decides
    or adjusts either one.
    """
    if not is_supported_language(language):
        raise KeyError(f"Unsupported voice language: {language!r}")
    return _STATEMENTS[level][language].format(score=score)
