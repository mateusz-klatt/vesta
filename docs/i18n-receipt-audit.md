# Receipt translation audit

Reviewed the 58 app keys and camera purpose added by `585b7ea` / `b091ace` in all 43 machine-translated locales. Accepted 119 corrections across 29 locales. English and Polish source wording, keys, placeholders, and catalog structures are unchanged. Ordinary grammatical inflection of iPhone is retained.

## Scope

### Localizable.xcstrings

- `0.00`
- `Add receipt`
- `BLIK`
- `Back to text`
- `Bank transaction`
- `Bank transaction changed`
- `Budget unavailable`
- `Card`
- `Cash`
- `Choose a photo`
- `Confirm or discard some drafts on the server, then try again.`
- `Date`
- `Don’t link`
- `Draft no longer exists`
- `Drafts expire after 48 hours. Scan the receipt again.`
- `Fix anything misread, then send it to your server to read the receipt.`
- `Fix the receipt text so the item totals add up to the total, then read it again.`
- `Items (%lld)`
- `Items and total differ by %@. Go back and fix the text.`
- `Mixed`
- `NIP`
- `No matching transaction yet. You can save the receipt without one.`
- `Not allowed`
- `Only an admin can add receipts, and the server must allow the app to send them.`
- `Paste text`
- `Payment`
- `Pick a different transaction or save the receipt without one.`
- `Purchase`
- `Read receipt`
- `Receipt`
- `Receipt changed elsewhere`
- `Receipt rejected`
- `Receipt saved`
- `Receipt text is too long`
- `Receipts are turned off`
- `Recognised text`
- `Refund`
- `Save receipt`
- `Scan receipt`
- `Scan the receipt again to refresh the matching transactions.`
- `Scan the receipt again to start from the current version.`
- `Set date`
- `Shop`
- `Shop or NIP changed, so these matches no longer apply. Save without a link, or go back and read the text again.`
- `Some item amounts don’t add up. Go back and fix the text.`
- `Start over`
- `Text is read on this iPhone. Only the text is sent to your server, with card numbers removed. The photo is not saved or uploaded.`
- `The receipt is too large for the server. Shorten the text and read it again.`
- `The server could not accept this receipt.`
- `The server owner has not enabled receipts yet.`
- `The server’s budget module is not available right now.`
- `This iPhone can’t read Polish characters yet — check ą, ę, ł, ż in product names.`
- `Time (HH:MM)`
- `Too many open drafts`
- `Total`
- `Totals don’t add up`
- `Transaction already has a receipt`
- `Type`

### InfoPlist.xcstrings

- `NSCameraUsageDescription`

## Corrections by locale

Each entry identifies the catalog/key, old text, replacement, and reason. Finance terminology changes are explicitly marked.

### ar (1)

- **Localizable: Confirm or discard some drafts on the server, then try again.**
  - Before: أكّد بعض المسودات على الخادم أو تجاهلها، ثم حاول مجددًا.
  - After: أكّد بعض المسودات على الخادم أو احذفها، ثم حاول مجددًا.
  - Discarding drafts must free server slots; the existing verb means ignore them, which does not convey removal.

### bs (1)

- **Localizable: Too many open drafts**
  - Before: Previše otvorenih skica
  - After: Previše otvorenih nacrta
  - Use nacrt consistently with all other draft messages; skica introduces a second term for the same object.

### cs (7)

- **InfoPlist: NSCameraUsageDescription**
  - Before: Vesta používá fotoaparát ke skenování účtenky. Text se čte na tvém iPhonu; fotka se neukládá ani nenahrává.
  - After: Vesta používá fotoaparát ke skenování účtenky. Text se čte na vašem iPhonu; fotka se neukládá ani nenahrává.
  - Keep the formal address used by the existing Czech catalog and the earlier receipt instructions; this string switches to informal address.
- **Localizable: Scan the receipt again to start from the current version.**
  - Before: Chceš-li začít od aktuální verze, naskenuj účtenku znovu.
  - After: Chcete-li začít od aktuální verze, naskenujte účtenku znovu.
  - Keep the formal address used by the existing Czech catalog and the earlier receipt instructions; this string switches to informal address.
- **Localizable: Shop or NIP changed, so these matches no longer apply. Save without a link, or go back and read the text again.**
  - Before: Změnil se obchod nebo NIP, takže nalezené shody už neplatí. Ulož bez propojení, nebo se vrať a text znovu načti.
  - After: Změnil se obchod nebo NIP, takže nalezené shody už neplatí. Uložte bez propojení, nebo se vraťte a text znovu načtěte.
  - Keep the formal address used by the existing Czech catalog and the earlier receipt instructions; this string switches to informal address.
- **Localizable: Some item amounts don’t add up. Go back and fix the text.**
  - Before: Částky některých položek nesedí. Vrať se a oprav text.
  - After: Částky některých položek nesedí. Vraťte se a opravte text.
  - Keep the formal address used by the existing Czech catalog and the earlier receipt instructions; this string switches to informal address.
- **Localizable: Text is read on this iPhone. Only the text is sent to your server, with card numbers removed. The photo is not saved or uploaded.**
  - Before: Text se čte přímo v tomto iPhonu. Na tvůj server se odesílá pouze text bez čísel karet. Fotka se neukládá ani nenahrává.
  - After: Text se čte přímo v tomto iPhonu. Na váš server se odesílá pouze text bez čísel karet. Fotka se neukládá ani nenahrává.
  - Keep the formal address used by the existing Czech catalog and the earlier receipt instructions; this string switches to informal address.
- **Localizable: The receipt is too large for the server. Shorten the text and read it again.**
  - Before: Účtenka je pro server příliš velká. Zkrať text a načti ho znovu.
  - After: Účtenka je pro server příliš velká. Zkraťte text a načtěte ho znovu.
  - Keep the formal address used by the existing Czech catalog and the earlier receipt instructions; this string switches to informal address.
- **Localizable: This iPhone can’t read Polish characters yet — check ą, ę, ł, ż in product names.**
  - Before: Tento iPhone zatím neumí číst polské znaky — zkontroluj ą, ę, ł, ż v názvech produktů.
  - After: Tento iPhone zatím neumí číst polské znaky — zkontrolujte ą, ę, ł, ż v názvech produktů.
  - Keep the formal address used by the existing Czech catalog and the earlier receipt instructions; this string switches to informal address.

### de (6)

- **InfoPlist: NSCameraUsageDescription**
  - Before: Vesta verwendet die Kamera zum Scannen eines Kassenbons. Der Text wird auf deinem iPhone gelesen; das Foto wird weder gespeichert noch hochgeladen.
  - After: Vesta verwendet die Kamera zum Scannen eines Belegs. Der Text wird auf deinem iPhone gelesen; das Foto wird weder gespeichert noch hochgeladen.
  - Finance terminology — Use Beleg consistently with the receipt flow instead of switching to Kassenbon in the permission prompt.
- **Localizable: Scan the receipt again to start from the current version.**
  - Before: Scanne den Kassenbon erneut, um mit der aktuellen Version zu beginnen.
  - After: Scanne den Beleg erneut, um mit der aktuellen Version zu beginnen.
  - Finance terminology — Use Beleg consistently with the receipt title, buttons, and other receipt errors; Kassenbon unnecessarily changes the name of the same document.
- **Localizable: The receipt is too large for the server. Shorten the text and read it again.**
  - Before: Der Kassenbon ist zu groß für den Server. Kürze den Text und lies ihn erneut.
  - After: Der Beleg ist zu groß für den Server. Kürze den Text und lies ihn erneut.
  - Finance terminology — Use Beleg consistently with the receipt title, buttons, and other receipt errors; Kassenbon unnecessarily changes the name of the same document.
- **Localizable: The server could not accept this receipt.**
  - Before: Der Server konnte diesen Kassenbon nicht akzeptieren.
  - After: Der Server konnte diesen Beleg nicht akzeptieren.
  - Finance terminology — Use Beleg consistently with the receipt title, buttons, and other receipt errors; Kassenbon unnecessarily changes the name of the same document.
- **Localizable: The server owner has not enabled receipts yet.**
  - Before: Der Besitzer des Servers hat Kassenbons noch nicht aktiviert.
  - After: Der Besitzer des Servers hat Belege noch nicht aktiviert.
  - Finance terminology — Use Beleg consistently with the receipt title, buttons, and other receipt errors; Kassenbon unnecessarily changes the name of the same document.
- **Localizable: Transaction already has a receipt**
  - Before: Die Transaktion hat bereits einen Kassenbon
  - After: Die Transaktion hat bereits einen Beleg
  - Finance terminology — Use Beleg consistently with the receipt title, buttons, and other receipt errors; Kassenbon unnecessarily changes the name of the same document.

### el (7)

- **InfoPlist: NSCameraUsageDescription**
  - Before: Η Vesta χρησιμοποιεί την κάμερα για σάρωση απόδειξης. Το κείμενο διαβάζεται στο iPhone σου· η φωτογραφία δεν αποθηκεύεται ούτε μεταφορτώνεται.
  - After: Το Vesta χρησιμοποιεί την κάμερα για σάρωση απόδειξης. Το κείμενο διαβάζεται στο iPhone σας· η φωτογραφία δεν αποθηκεύεται ούτε μεταφορτώνεται.
  - Keep the polite plural address used by the existing Greek catalog and the earlier receipt instructions; this string switches to singular address. Also match the existing purpose string’s Το Vesta.
- **Localizable: Scan the receipt again to start from the current version.**
  - Before: Σάρωσε ξανά την απόδειξη για να ξεκινήσεις από την τρέχουσα έκδοση.
  - After: Σαρώστε ξανά την απόδειξη για να ξεκινήσετε από την τρέχουσα έκδοση.
  - Keep the polite plural address used by the existing Greek catalog and the earlier receipt instructions; this string switches to singular address.
- **Localizable: Shop or NIP changed, so these matches no longer apply. Save without a link, or go back and read the text again.**
  - Before: Το κατάστημα ή το NIP άλλαξε, επομένως αυτές οι αντιστοιχίσεις δεν ισχύουν πλέον. Αποθήκευσε χωρίς σύνδεση ή γύρνα πίσω και διάβασε ξανά το κείμενο.
  - After: Το κατάστημα ή το NIP άλλαξε, επομένως αυτές οι αντιστοιχίσεις δεν ισχύουν πλέον. Αποθηκεύστε χωρίς σύνδεση ή επιστρέψτε και διαβάστε ξανά το κείμενο.
  - Keep the polite plural address used by the existing Greek catalog and the earlier receipt instructions; this string switches to singular address.
- **Localizable: Some item amounts don’t add up. Go back and fix the text.**
  - Before: Τα ποσά ορισμένων ειδών δεν βγαίνουν. Γύρνα πίσω και διόρθωσε το κείμενο.
  - After: Τα ποσά ορισμένων ειδών δεν βγαίνουν. Επιστρέψτε και διορθώστε το κείμενο.
  - Keep the polite plural address used by the existing Greek catalog and the earlier receipt instructions; this string switches to singular address.
- **Localizable: Text is read on this iPhone. Only the text is sent to your server, with card numbers removed. The photo is not saved or uploaded.**
  - Before: Το κείμενο διαβάζεται σε αυτό το iPhone. Στον διακομιστή σου αποστέλλεται μόνο το κείμενο, χωρίς τους αριθμούς καρτών. Η φωτογραφία δεν αποθηκεύεται ούτε μεταφορτώνεται.
  - After: Το κείμενο διαβάζεται σε αυτό το iPhone. Στον διακομιστή σας αποστέλλεται μόνο το κείμενο, χωρίς τους αριθμούς καρτών. Η φωτογραφία δεν αποθηκεύεται ούτε μεταφορτώνεται.
  - Keep the polite plural address used by the existing Greek catalog and the earlier receipt instructions; this string switches to singular address.
- **Localizable: The receipt is too large for the server. Shorten the text and read it again.**
  - Before: Η απόδειξη είναι πολύ μεγάλη για τον διακομιστή. Περίκοψε το κείμενο και διάβασέ το ξανά.
  - After: Η απόδειξη είναι πολύ μεγάλη για τον διακομιστή. Συντομεύστε το κείμενο και διαβάστε το ξανά.
  - Keep the polite plural address used by the existing Greek catalog and the earlier receipt instructions; this string switches to singular address.
- **Localizable: This iPhone can’t read Polish characters yet — check ą, ę, ł, ż in product names.**
  - Before: Αυτό το iPhone δεν μπορεί ακόμη να διαβάσει πολωνικούς χαρακτήρες — έλεγξε τα ą, ę, ł, ż στα ονόματα προϊόντων.
  - After: Αυτό το iPhone δεν μπορεί ακόμη να διαβάσει πολωνικούς χαρακτήρες — ελέγξτε τα ą, ę, ł, ż στα ονόματα προϊόντων.
  - Keep the polite plural address used by the existing Greek catalog and the earlier receipt instructions; this string switches to singular address.

### es (6)

- **InfoPlist: NSCameraUsageDescription**
  - Before: Vesta usa la cámara para escanear un recibo. El texto se lee en tu iPhone; la foto no se guarda ni se sube.
  - After: Vesta usa la cámara para escanear un ticket. El texto se lee en tu iPhone; la foto no se guarda ni se sube.
  - Finance terminology — Use ticket consistently with the retail receipt flow in the camera purpose string.
- **Localizable: Scan the receipt again to start from the current version.**
  - Before: Escanea el recibo otra vez para empezar desde la versión actual.
  - After: Escanea el ticket otra vez para empezar desde la versión actual.
  - Finance terminology — Use ticket consistently with the receipt title, buttons, and other errors; recibo changes terminology for the same retail receipt.
- **Localizable: The receipt is too large for the server. Shorten the text and read it again.**
  - Before: El recibo es demasiado grande para el servidor. Acorta el texto y léelo de nuevo.
  - After: El ticket es demasiado grande para el servidor. Acorta el texto y léelo de nuevo.
  - Finance terminology — Use ticket consistently with the receipt title, buttons, and other errors; recibo changes terminology for the same retail receipt.
- **Localizable: The server could not accept this receipt.**
  - Before: El servidor no pudo aceptar este recibo.
  - After: El servidor no pudo aceptar este ticket.
  - Finance terminology — Use ticket consistently with the receipt title, buttons, and other errors; recibo changes terminology for the same retail receipt.
- **Localizable: The server owner has not enabled receipts yet.**
  - Before: El propietario del servidor aún no ha activado los recibos.
  - After: El propietario del servidor aún no ha activado los tickets.
  - Finance terminology — Use ticket consistently with the receipt title, buttons, and other errors; recibo changes terminology for the same retail receipt.
- **Localizable: Transaction already has a receipt**
  - Before: La transacción ya tiene un recibo
  - After: La transacción ya tiene un ticket
  - Finance terminology — Use ticket consistently with the receipt title, buttons, and other errors; recibo changes terminology for the same retail receipt.

### fa (7)

- **InfoPlist: NSCameraUsageDescription**
  - Before: Vesta از دوربین برای اسکن رسید استفاده می‌کند. متن روی iPhone تو خوانده می‌شود؛ عکس ذخیره یا بارگذاری نمی‌شود.
  - After: Vesta از دوربین برای اسکن رسید استفاده می‌کند. متن روی iPhone شما خوانده می‌شود؛ عکس ذخیره یا بارگذاری نمی‌شود.
  - Uses the established polite form of address from the existing Persian catalog and earlier receipt instructions; removes the abrupt switch to informal singular.
- **Localizable: Scan the receipt again to start from the current version.**
  - Before: برای شروع از نسخهٔ فعلی، رسید را دوباره اسکن کن.
  - After: برای شروع از نسخهٔ فعلی، رسید را دوباره اسکن کنید.
  - Uses the established polite form of address from the existing Persian catalog and earlier receipt instructions; removes the abrupt switch to informal singular.
- **Localizable: Shop or NIP changed, so these matches no longer apply. Save without a link, or go back and read the text again.**
  - Before: فروشگاه یا NIP تغییر کرده است، بنابراین این تطبیق‌ها دیگر معتبر نیستند. بدون پیوند ذخیره کن یا برگرد و متن را دوباره بخوان.
  - After: فروشگاه یا NIP تغییر کرده است، بنابراین این تطبیق‌ها دیگر معتبر نیستند. بدون پیوند ذخیره کنید یا برگردید و متن را دوباره بخوانید.
  - Uses the established polite form of address from the existing Persian catalog and earlier receipt instructions; removes the abrupt switch to informal singular.
- **Localizable: Some item amounts don’t add up. Go back and fix the text.**
  - Before: مبلغ برخی اقلام درست جمع نمی‌شود. برگرد و متن را اصلاح کن.
  - After: مبلغ برخی اقلام درست جمع نمی‌شود. برگردید و متن را اصلاح کنید.
  - Uses the established polite form of address from the existing Persian catalog and earlier receipt instructions; removes the abrupt switch to informal singular.
- **Localizable: Text is read on this iPhone. Only the text is sent to your server, with card numbers removed. The photo is not saved or uploaded.**
  - Before: متن روی همین iPhone خوانده می‌شود. فقط متن، بدون شماره کارت‌ها، به سرور تو ارسال می‌شود. عکس ذخیره یا بارگذاری نمی‌شود.
  - After: متن روی همین iPhone خوانده می‌شود. فقط متن، بدون شماره کارت‌ها، به سرور شما ارسال می‌شود. عکس ذخیره یا بارگذاری نمی‌شود.
  - Uses the established polite form of address from the existing Persian catalog and earlier receipt instructions; removes the abrupt switch to informal singular.
- **Localizable: The receipt is too large for the server. Shorten the text and read it again.**
  - Before: رسید برای سرور بیش از حد بزرگ است. متن را کوتاه کن و دوباره بخوان.
  - After: رسید برای سرور بیش از حد بزرگ است. متن را کوتاه کنید و دوباره بخوانید.
  - Uses the established polite form of address from the existing Persian catalog and earlier receipt instructions; removes the abrupt switch to informal singular.
- **Localizable: This iPhone can’t read Polish characters yet — check ą, ę, ł, ż in product names.**
  - Before: این iPhone هنوز نمی‌تواند نویسه‌های لهستانی را بخواند — ą, ę, ł, ż را در نام محصولات بررسی کن.
  - After: این iPhone هنوز نمی‌تواند نویسه‌های لهستانی را بخواند — ą, ę, ł, ż را در نام محصولات بررسی کنید.
  - Uses the established polite form of address from the existing Persian catalog and earlier receipt instructions; removes the abrupt switch to informal singular.

### fi (1)

- **Localizable: Items and total differ by %@. Go back and fix the text.**
  - Before: Tuotteiden ja loppusumman välillä on %@ ero. Palaa takaisin ja korjaa teksti.
  - After: Tuotteiden summan ja loppusumman erotus on %@. Palaa takaisin ja korjaa teksti.
  - Avoid the uninflected %@ ero construction, which needs a genitive ending that cannot safely be attached to arbitrary formatted currency; the amount now follows on unchanged.

### fr (10)

- **InfoPlist: NSCameraUsageDescription**
  - Before: Vesta utilise l’appareil photo pour scanner un reçu. Le texte est lu sur ton iPhone ; la photo n’est ni enregistrée ni téléversée.
  - After: Vesta utilise l’appareil photo pour scanner un ticket. Le texte est lu sur votre iPhone ; la photo n’est ni enregistrée ni téléversée.
  - Finance terminology — Use vous consistently with the existing French catalog and earlier receipt instructions; this string switches to tu. Use ticket consistently with the receipt title, buttons, and other errors instead of switching to reçu.
- **Localizable: Scan the receipt again to start from the current version.**
  - Before: Scanne le reçu à nouveau pour repartir de la version actuelle.
  - After: Scannez le ticket à nouveau pour repartir de la version actuelle.
  - Finance terminology — Use vous consistently with the existing French catalog and earlier receipt instructions; this string switches to tu. Use ticket consistently with the receipt title, buttons, and other errors instead of switching to reçu.
- **Localizable: Shop or NIP changed, so these matches no longer apply. Save without a link, or go back and read the text again.**
  - Before: Le magasin ou le NIP a changé : ces correspondances ne sont donc plus valables. Enregistre sans lien ou reviens en arrière pour relire le texte.
  - After: Le magasin ou le NIP a changé : ces correspondances ne sont donc plus valables. Enregistrez sans lien ou revenez en arrière pour relire le texte.
  - Use vous consistently with the existing French catalog and earlier receipt instructions; this string switches to tu.
- **Localizable: Some item amounts don’t add up. Go back and fix the text.**
  - Before: Les montants de certains articles ne concordent pas. Reviens en arrière et corrige le texte.
  - After: Les montants de certains articles ne concordent pas. Revenez en arrière et corrigez le texte.
  - Use vous consistently with the existing French catalog and earlier receipt instructions; this string switches to tu.
- **Localizable: Text is read on this iPhone. Only the text is sent to your server, with card numbers removed. The photo is not saved or uploaded.**
  - Before: Le texte est lu sur cet iPhone. Seul le texte est envoyé à ton serveur, sans les numéros de carte. La photo n’est ni enregistrée ni téléversée.
  - After: Le texte est lu sur cet iPhone. Seul le texte est envoyé à votre serveur, sans les numéros de carte. La photo n’est ni enregistrée ni téléversée.
  - Use vous consistently with the existing French catalog and earlier receipt instructions; this string switches to tu.
- **Localizable: The receipt is too large for the server. Shorten the text and read it again.**
  - Before: Le reçu est trop volumineux pour le serveur. Raccourcis le texte et relis-le.
  - After: Le ticket est trop volumineux pour le serveur. Raccourcissez le texte et relisez-le.
  - Finance terminology — Use vous consistently with the existing French catalog and earlier receipt instructions; this string switches to tu. Use ticket consistently with the receipt title, buttons, and other errors instead of switching to reçu.
- **Localizable: The server could not accept this receipt.**
  - Before: Le serveur n’a pas pu accepter ce reçu.
  - After: Le serveur n’a pas pu accepter ce ticket.
  - Finance terminology — Use ticket consistently with the receipt title, buttons, and other errors instead of switching to reçu.
- **Localizable: The server owner has not enabled receipts yet.**
  - Before: Le propriétaire du serveur n’a pas encore activé les reçus.
  - After: Le propriétaire du serveur n’a pas encore activé les tickets.
  - Finance terminology — Use ticket consistently with the receipt title, buttons, and other errors instead of switching to reçu.
- **Localizable: This iPhone can’t read Polish characters yet — check ą, ę, ł, ż in product names.**
  - Before: Cet iPhone ne sait pas encore lire les caractères polonais — vérifie ą, ę, ł, ż dans les noms des produits.
  - After: Cet iPhone ne sait pas encore lire les caractères polonais — vérifiez ą, ę, ł, ż dans les noms des produits.
  - Use vous consistently with the existing French catalog and earlier receipt instructions; this string switches to tu.
- **Localizable: Transaction already has a receipt**
  - Before: La transaction a déjà un reçu
  - After: La transaction a déjà un ticket
  - Finance terminology — Use ticket consistently with the receipt title, buttons, and other errors instead of switching to reçu.

### ga (2)

- **Localizable: Fix the receipt text so the item totals add up to the total, then read it again.**
  - Before: Ceartaigh téacs na admhála chun go mbeidh suim na n-earraí cothrom leis an iomlán, ansin léigh arís é.
  - After: Ceartaigh téacs na hadmhála chun go mbeidh suim na n-earraí cothrom leis an iomlán, ansin léigh arís é.
  - Correct the missing h-prefix in the genitive singular after na: na hadmhála. The financial term itself stays admháil. Verified in Teanglann grammar: https://www.teanglann.ie/en/gram/admh%C3%A1il.
- **Localizable: Receipt text is too long**
  - Before: Tá téacs na admhála rófhada
  - After: Tá téacs na hadmhála rófhada
  - Correct the missing h-prefix in the genitive singular after na: na hadmhála. The financial term itself stays admháil. Verified in Teanglann grammar: https://www.teanglann.ie/en/gram/admh%C3%A1il.

### he (1)

- **Localizable: Fix anything misread, then send it to your server to read the receipt.**
  - Before: תקן כל דבר שנקרא בטעות, ולאחר מכן שלח את הטקסט לשרת שלך כדי שיקרא את הקבלה.
  - After: תקן כל דבר שנקרא באופן שגוי, ולאחר מכן שלח את הטקסט לשרת שלך כדי שיקרא את הקבלה.
  - The existing phrase means read by accident, rather than read incorrectly; the replacement describes OCR errors.

### hu (15)

- **InfoPlist: NSCameraUsageDescription**
  - Before: A Vesta a kamerát blokk beolvasására használja. A szöveg az iPhoneodon kerül beolvasásra; a fotó nem kerül mentésre vagy feltöltésre.
  - After: A Vesta a kamerát nyugta beolvasására használja. A szöveg az iPhoneodon kerül beolvasásra; a fotó nem kerül mentésre vagy feltöltésre.
  - Finance terminology — Use nyugta consistently with the receipt flow instead of switching to blokk in the camera prompt.
- **Localizable: Confirm or discard some drafts on the server, then try again.**
  - Before: Hagyjon jóvá vagy vessen el néhány piszkozatot a szerveren, majd próbálja újra.
  - After: Hagyj jóvá vagy vess el néhány piszkozatot a szerveren, majd próbáld újra.
  - Match the informal address established in the existing Hungarian catalog and the later receipt instructions; the current wording switches to formal address.
- **Localizable: Don’t link**
  - Before: Ne kapcsolja
  - After: Ne kapcsold össze
  - Match the informal address established in the existing Hungarian catalog and the later receipt instructions; the current wording switches to formal address. Include össze for linking records together.
- **Localizable: Drafts expire after 48 hours. Scan the receipt again.**
  - Before: A piszkozatok 48 óra elteltével lejárnak. Szkennelje be újra a nyugtát.
  - After: A piszkozatok 48 óra elteltével lejárnak. Szkenneld be újra a nyugtát.
  - Match the informal address established in the existing Hungarian catalog and the later receipt instructions; the current wording switches to formal address.
- **Localizable: Fix anything misread, then send it to your server to read the receipt.**
  - Before: Javítsa ki a tévesen felismert részeket, majd küldje el a szöveget a szerverére a nyugta beolvasásához.
  - After: Javítsd ki a tévesen felismert részeket, majd küldd el a szöveget a szerveredre a nyugta beolvasásához.
  - Match the informal address established in the existing Hungarian catalog and the later receipt instructions; the current wording switches to formal address.
- **Localizable: Fix the receipt text so the item totals add up to the total, then read it again.**
  - Before: Javítsa ki a nyugta szövegét úgy, hogy a tételek összege egyezzen a végösszeggel, majd olvassa be újra.
  - After: Javítsd ki a nyugta szövegét úgy, hogy a tételek összege egyezzen a végösszeggel, majd olvasd be újra.
  - Match the informal address established in the existing Hungarian catalog and the later receipt instructions; the current wording switches to formal address.
- **Localizable: Items and total differ by %@. Go back and fix the text.**
  - Before: A tételek és a végösszeg között %@ az eltérés. Menjen vissza, és javítsa ki a szöveget.
  - After: A tételek és a végösszeg között %@ az eltérés. Menj vissza, és javítsd ki a szöveget.
  - Match the informal address established in the existing Hungarian catalog and the later receipt instructions; the current wording switches to formal address.
- **Localizable: Pick a different transaction or save the receipt without one.**
  - Before: Válasszon másik tranzakciót, vagy mentse a nyugtát anélkül.
  - After: Válassz másik tranzakciót, vagy mentsd a nyugtát anélkül.
  - Match the informal address established in the existing Hungarian catalog and the later receipt instructions; the current wording switches to formal address.
- **Localizable: Scan the receipt again to refresh the matching transactions.**
  - Before: Szkennelje be újra a nyugtát a megfelelő tranzakciók frissítéséhez.
  - After: Szkenneld be újra a nyugtát a megfelelő tranzakciók frissítéséhez.
  - Match the informal address established in the existing Hungarian catalog and the later receipt instructions; the current wording switches to formal address.
- **Localizable: Scan the receipt again to start from the current version.**
  - Before: Az aktuális verzióról való induláshoz olvasd be újra a blokkot.
  - After: Az aktuális verzióról való induláshoz olvasd be újra a nyugtát.
  - Finance terminology — Use nyugta consistently with the receipt title, buttons, and other errors instead of switching to the colloquial synonym blokk.
- **Localizable: The receipt is too large for the server. Shorten the text and read it again.**
  - Before: A blokk túl nagy a szerver számára. Rövidítsd a szöveget, és olvasd be újra.
  - After: A nyugta túl nagy a szerver számára. Rövidítsd a szöveget, és olvasd be újra.
  - Finance terminology — Use nyugta consistently with the receipt title, buttons, and other errors instead of switching to the colloquial synonym blokk.
- **Localizable: The server could not accept this receipt.**
  - Before: A szerver nem tudta elfogadni ezt a blokkot.
  - After: A szerver nem tudta elfogadni ezt a nyugtát.
  - Finance terminology — Use nyugta consistently with the receipt title, buttons, and other errors instead of switching to the colloquial synonym blokk.
- **Localizable: The server owner has not enabled receipts yet.**
  - Before: A szerver tulajdonosa még nem engedélyezte a blokkokat.
  - After: A szerver tulajdonosa még nem engedélyezte a nyugtákat.
  - Finance terminology — Use nyugta consistently with the receipt title, buttons, and other errors instead of switching to the colloquial synonym blokk.
- **Localizable: Too many open drafts**
  - Before: Túl sok nyitott vázlat
  - After: Túl sok nyitott piszkozat
  - Use piszkozat consistently with the other draft messages; vázlat introduces a second term for the same object.
- **Localizable: Transaction already has a receipt**
  - Before: A tranzakcióhoz már tartozik blokk
  - After: A tranzakcióhoz már tartozik nyugta
  - Finance terminology — Use nyugta consistently with the receipt title, buttons, and other errors instead of switching to the colloquial synonym blokk.

### hy (2)

- **InfoPlist: NSCameraUsageDescription**
  - Before: Vesta-ն օգտագործում է տեսախցիկը անդորրագիր սկանավորելու համար։ Տեքստը կարդացվում է քո iPhone-ում; լուսանկարը չի պահպանվում և չի վերբեռնվում։
  - After: Vesta-ն օգտագործում է տեսախցիկը անդորրագիր սկանավորելու համար։ Տեքստը կարդացվում է ձեր iPhone-ում; լուսանկարը չի պահպանվում և չի վերբեռնվում։
  - Uses the existing Armenian catalog’s polite ձեր instead of unexpectedly switching to informal քո.
- **Localizable: Text is read on this iPhone. Only the text is sent to your server, with card numbers removed. The photo is not saved or uploaded.**
  - Before: Տեքստը կարդացվում է այս iPhone-ում։ Քո սերվեր է ուղարկվում միայն տեքստը՝ առանց քարտերի համարների։ Լուսանկարը չի պահպանվում և չի վերբեռնվում։
  - After: Տեքստը կարդացվում է այս iPhone-ում։ Ձեր սերվեր է ուղարկվում միայն տեքստը՝ առանց քարտերի համարների։ Լուսանկարը չի պահպանվում և չի վերբեռնվում։
  - Uses the existing Armenian catalog’s polite ձեր instead of unexpectedly switching to informal քո.

### id (2)

- **InfoPlist: NSCameraUsageDescription**
  - Before: Vesta menggunakan kamera untuk memindai struk. Teks dibaca di iPhone kamu; foto tidak disimpan atau diunggah.
  - After: Vesta menggunakan kamera untuk memindai struk. Teks dibaca di iPhone Anda; foto tidak disimpan atau diunggah.
  - Uses Anda, the established address in the Indonesian catalog and the receipt instructions, instead of informal kamu.
- **Localizable: Text is read on this iPhone. Only the text is sent to your server, with card numbers removed. The photo is not saved or uploaded.**
  - Before: Teks dibaca di iPhone ini. Hanya teks yang dikirim ke server kamu, dengan nomor kartu dihapus. Foto tidak disimpan atau diunggah.
  - After: Teks dibaca di iPhone ini. Hanya teks yang dikirim ke server Anda, dengan nomor kartu dihapus. Foto tidak disimpan atau diunggah.
  - Uses Anda, the established address in the Indonesian catalog and the receipt instructions, instead of informal kamu.

### is (8)

- **InfoPlist: NSCameraUsageDescription**
  - Before: Vesta notar myndavélina til að skanna kvittun. Textinn er lesinn á iPhone-inum þínum; myndin er hvorki vistuð né hlaðið upp.
  - After: Vesta notar myndavélina til að skanna kvittun. Textinn er lesinn á iPhone-inum þínum; myndin er ekki vistuð og henni er ekki hlaðið upp.
  - Correct the coordinated passive: hlaða upp takes a dative object (henni), so it cannot share nominative myndin with vistuð.
- **Localizable: Bank transaction**
  - Before: Bankaviðskipti
  - After: Bankafærsla
  - Finance terminology — Use færsla for a bank ledger transaction, matching the existing transaction-already-linked message. Viðskipti refers broadly to dealings/trade. Banking usage verified at https://www.landsbankinn.is/fyrirtaeki/kort/vidbot-vid-kortafaerslur.
- **Localizable: Bank transaction changed**
  - Before: Bankaviðskiptunum hefur verið breytt
  - After: Bankafærslunni hefur verið breytt
  - Finance terminology — Use færsla for a bank ledger transaction, matching the existing transaction-already-linked message. Viðskipti refers broadly to dealings/trade. Banking usage verified at https://www.landsbankinn.is/fyrirtaeki/kort/vidbot-vid-kortafaerslur.
- **Localizable: Fix anything misread, then send it to your server to read the receipt.**
  - Before: Lagaðu allt sem las rangt og sendu síðan textann á þjóninn þinn til að lesa kvittunina.
  - After: Lagaðu allt sem var rangt lesið og sendu síðan textann á þjóninn þinn til að lesa kvittunina.
  - Use passive var rangt lesið: the current text means the thing itself read incorrectly, rather than was misread.
- **Localizable: No matching transaction yet. You can save the receipt without one.**
  - Before: Engin samsvarandi viðskipti eru enn til. Þú getur vistað kvittunina án þeirra.
  - After: Engin samsvarandi færsla er enn til. Þú getur vistað kvittunina án hennar.
  - Finance terminology — Use færsla for a bank ledger transaction, matching the existing transaction-already-linked message. Viðskipti refers broadly to dealings/trade. Banking usage verified at https://www.landsbankinn.is/fyrirtaeki/kort/vidbot-vid-kortafaerslur.
- **Localizable: Pick a different transaction or save the receipt without one.**
  - Before: Veldu önnur viðskipti eða vistaðu kvittunina án þeirra.
  - After: Veldu aðra færslu eða vistaðu kvittunina án hennar.
  - Finance terminology — Use færsla for a bank ledger transaction, matching the existing transaction-already-linked message. Viðskipti refers broadly to dealings/trade. Banking usage verified at https://www.landsbankinn.is/fyrirtaeki/kort/vidbot-vid-kortafaerslur.
- **Localizable: Scan the receipt again to refresh the matching transactions.**
  - Before: Skannaðu kvittunina aftur til að endurnýja samsvarandi viðskipti.
  - After: Skannaðu kvittunina aftur til að endurnýja samsvarandi færslur.
  - Finance terminology — Use færsla for a bank ledger transaction, matching the existing transaction-already-linked message. Viðskipti refers broadly to dealings/trade. Banking usage verified at https://www.landsbankinn.is/fyrirtaeki/kort/vidbot-vid-kortafaerslur.
- **Localizable: Text is read on this iPhone. Only the text is sent to your server, with card numbers removed. The photo is not saved or uploaded.**
  - Before: Textinn er lesinn á þessum iPhone. Aðeins textinn er sendur á þjóninn þinn, með kortanúmerum fjarlægðum. Myndin er hvorki vistuð né hlaðið upp.
  - After: Textinn er lesinn á þessum iPhone. Aðeins textinn er sendur á þjóninn þinn, með kortanúmerum fjarlægðum. Myndin er ekki vistuð og henni er ekki hlaðið upp.
  - Correct the coordinated passive: hlaða upp takes a dative object (henni), so it cannot share nominative myndin with vistuð.

### ja (1)

- **Localizable: Confirm or discard some drafts on the server, then try again.**
  - Before: サーバー上の下書きをいくつか確認または破棄してから、もう一度お試しください。
  - After: サーバー上の下書きをいくつか確定または破棄してから、もう一度お試しください。
  - Drafts must be finalized or discarded to free slots; 確認 means inspect/check, while 確定 expresses the required finalization.

### ko (1)

- **InfoPlist: NSCameraUsageDescription**
  - Before: Vesta가 영수증을 스캔하기 위해 침라를 사용합니다. 텍스트는 iPhone에서 읽히며 사진은 저장되거나 업로드되지 않습니다.
  - After: Vesta가 영수증을 스캔하기 위해 카메라를 사용합니다. 텍스트는 iPhone에서 읽히며 사진은 저장되거나 업로드되지 않습니다.
  - Corrects a corrupted word for camera; 침라 is not the Korean term.

### lt (2)

- **Localizable: Don’t link**
  - Before: Nesiekti
  - After: Nesusieti
  - Nesiekti means not to pursue/reach; Nesusieti correctly means not to link the transaction.
- **Localizable: Mixed**
  - Before: Mišri
  - After: Mišrus
  - Finance terminology — Correct adjective agreement with Mokėjimas (payment) and mokėjimo būdas (payment method), both masculine.

### lv (7)

- **InfoPlist: NSCameraUsageDescription**
  - Before: Vesta izmanto kameru, lai skenētu kvīti. Teksts tiek nolasīts jūsu iPhone; fotoattēls netiek ne saglabāts, ne augšupielādēts.
  - After: Vesta izmanto kameru, lai skenētu čeku. Teksts tiek nolasīts jūsu iPhone; fotoattēls netiek ne saglabāts, ne augšupielādēts.
  - Finance terminology — Use čeks for the same retail receipt named Čeks throughout the scan UI.
- **Localizable: Mixed**
  - Before: Jaukta
  - After: Jaukts
  - Finance terminology — Correct adjective agreement with Maksājums (payment), masculine.
- **Localizable: Scan the receipt again to start from the current version.**
  - Before: Lai sāktu no pašreizējās versijas, vēlreiz skenējiet kvīti.
  - After: Lai sāktu no pašreizējās versijas, vēlreiz skenējiet čeku.
  - Finance terminology — Use čeks consistently for the scanned retail receipt, matching Receipt/Add receipt/Scan receipt; kvīts is a different/general payment document. Also fixes gender agreement where applicable.
- **Localizable: The receipt is too large for the server. Shorten the text and read it again.**
  - Before: Kvīts ir pārāk liels serverim. Saīsiniet tekstu un nolasiet to vēlreiz.
  - After: Čeks ir pārāk liels serverim. Saīsiniet tekstu un nolasiet to vēlreiz.
  - Finance terminology — Use čeks consistently for the scanned retail receipt, matching Receipt/Add receipt/Scan receipt; kvīts is a different/general payment document. Also fixes gender agreement where applicable.
- **Localizable: The server could not accept this receipt.**
  - Before: Serveris nevarēja pieņemt šo kvīti.
  - After: Serveris nevarēja pieņemt šo čeku.
  - Finance terminology — Use čeks consistently for the scanned retail receipt, matching Receipt/Add receipt/Scan receipt; kvīts is a different/general payment document. Also fixes gender agreement where applicable.
- **Localizable: The server owner has not enabled receipts yet.**
  - Before: Servera īpašnieks vēl nav iespējojis kvītis.
  - After: Servera īpašnieks vēl nav iespējojis čekus.
  - Finance terminology — Use čeks consistently for the scanned retail receipt, matching Receipt/Add receipt/Scan receipt; kvīts is a different/general payment document. Also fixes gender agreement where applicable.
- **Localizable: Transaction already has a receipt**
  - Before: Darījumam jau ir kvīts
  - After: Darījumam jau ir čeks
  - Finance terminology — Use čeks consistently for the scanned retail receipt, matching Receipt/Add receipt/Scan receipt; kvīts is a different/general payment document. Also fixes gender agreement where applicable.

### my (6)

- **Localizable: Bank transaction**
  - Before: ဘဏ်လုပ်ငန်း
  - After: ဘဏ်ငွေပေးငွေယူ
  - Finance terminology — Uses standard financial-transaction terminology (ငွေပေးငွေယူ), replacing a generic banking/business term; the UI represents individual bank transactions.
- **Localizable: Bank transaction changed**
  - Before: ဘဏ်လုပ်ငန်း ပြောင်းလဲသွားသည်
  - After: ဘဏ်ငွေပေးငွေယူ ပြောင်းလဲသွားသည်
  - Finance terminology — Uses standard financial-transaction terminology (ငွေပေးငွေယူ), replacing a generic banking/business term; the UI represents individual bank transactions.
- **Localizable: No matching transaction yet. You can save the receipt without one.**
  - Before: ကိုက်ညီသော ဘဏ်လုပ်ငန်း မရှိသေးပါ။ ထိုလုပ်ငန်းမပါဘဲ ပြေစာကိုသိမ်းဆည်းနိုင်သည်။
  - After: ကိုက်ညီသော ငွေပေးငွေယူ မရှိသေးပါ။ ငွေပေးငွေယူမပါဘဲ ပြေစာကိုသိမ်းဆည်းနိုင်သည်။
  - Finance terminology — Uses standard financial-transaction terminology (ငွေပေးငွေယူ), replacing a generic banking/business term; the UI represents individual bank transactions.
- **Localizable: Pick a different transaction or save the receipt without one.**
  - Before: အခြားလုပ်ငန်းတစ်ခုကို ရွေးချယ်ပါ သို့မဟုတ် ထိုလုပ်ငန်းမပါဘဲ ပြေစာကိုသိမ်းဆည်းပါ။
  - After: အခြားငွေပေးငွေယူတစ်ခုကို ရွေးချယ်ပါ သို့မဟုတ် ငွေပေးငွေယူမပါဘဲ ပြေစာကိုသိမ်းဆည်းပါ။
  - Finance terminology — Uses standard financial-transaction terminology (ငွေပေးငွေယူ), replacing a generic banking/business term; the UI represents individual bank transactions.
- **Localizable: Scan the receipt again to refresh the matching transactions.**
  - Before: ကိုက်ညီသော ဘဏ်လုပ်ငန်းများကိုစ်ပြန်ရယူရန် ပြေစာကို ထပ်စကင်န်ဖတ်ပါ။
  - After: ကိုက်ညီသော ငွေပေးငွေယူများကို ပြန်လည်ရယူရန် ပြေစာကို ထပ်စကင်န်ဖတ်ပါ။
  - Finance terminology — Uses standard financial-transaction terminology (ငွေပေးငွေယူ), replacing a generic banking/business term; the UI represents individual bank transactions. Also repairs the corrupted sequence များကိုစ်ပြန် in the refresh instruction.
- **Localizable: Transaction already has a receipt**
  - Before: ဤငွေလဲလှယ်မှုတွင် ပြေစာရှိပြီးသားဖြစ်သည်
  - After: ဤငွေပေးငွေယူတွင် ပြေစာရှိပြီးသားဖြစ်သည်
  - Finance terminology — Replaces currency exchange (ငွေလဲလှယ်မှု) with financial transaction (ငွေပေးငွေယူ), consistent with the other transaction keys.

### ro (1)

- **Localizable: Mixed**
  - Before: Mixt
  - After: Mixtă
  - Finance terminology — Correct adjective agreement with Plată (payment), feminine.

### ru (1)

- **Localizable: Transaction already has a receipt**
  - Before: У этой транзакции уже есть чек
  - After: У этой операции уже есть чек
  - Finance terminology — Use операция consistently with Bank transaction and all matching-transaction instructions, rather than changing the same entity to транзакция.

### sk (7)

- **InfoPlist: NSCameraUsageDescription**
  - Before: Vesta používa fotoaparát na skenovanie účtenky. Text sa číta v tvojom iPhone; fotka sa neukladá ani nenahráva.
  - After: Vesta používa fotoaparát na skenovanie účtenky. Text sa číta vo vašom iPhone; fotka sa neukladá ani nenahráva.
  - Use formal vašom consistently with the app’s Slovak instructions, with the corresponding vo preposition.
- **Localizable: Scan the receipt again to start from the current version.**
  - Before: Ak chceš začať od aktuálnej verzie, znova naskenuj účtenku.
  - After: Ak chcete začať od aktuálnej verzie, znova naskenujte účtenku.
  - Restore formal/plural address used by existing Slovak instructions and earlier receipt messages; change only the inconsistent pronouns/verb endings.
- **Localizable: Shop or NIP changed, so these matches no longer apply. Save without a link, or go back and read the text again.**
  - Before: Obchod alebo NIP sa zmenil, takže tieto zhody už neplatia. Ulož bez prepojenia alebo sa vráť a znovu načítaj text.
  - After: Obchod alebo NIP sa zmenil, takže tieto zhody už neplatia. Uložte bez prepojenia alebo sa vráťte a znovu načítajte text.
  - Restore formal/plural address used by existing Slovak instructions and earlier receipt messages; change only the inconsistent pronouns/verb endings.
- **Localizable: Some item amounts don’t add up. Go back and fix the text.**
  - Before: Sumy niektorých položiek nesedia. Vráť sa a oprav text.
  - After: Sumy niektorých položiek nesedia. Vráťte sa a opravte text.
  - Restore formal/plural address used by existing Slovak instructions and earlier receipt messages; change only the inconsistent pronouns/verb endings.
- **Localizable: Text is read on this iPhone. Only the text is sent to your server, with card numbers removed. The photo is not saved or uploaded.**
  - Before: Text sa číta v tomto iPhone. Na tvoj server sa odošle len text bez čísel kariet. Fotka sa neukladá ani nenahráva.
  - After: Text sa číta v tomto iPhone. Na váš server sa odošle len text bez čísel kariet. Fotka sa neukladá ani nenahráva.
  - Restore formal/plural address used by existing Slovak instructions and earlier receipt messages; change only the inconsistent pronouns/verb endings.
- **Localizable: The receipt is too large for the server. Shorten the text and read it again.**
  - Before: Účtenka je pre server príliš veľká. Skráť text a znovu ho načítaj.
  - After: Účtenka je pre server príliš veľká. Skráťte text a znovu ho načítajte.
  - Restore formal/plural address used by existing Slovak instructions and earlier receipt messages; change only the inconsistent pronouns/verb endings.
- **Localizable: This iPhone can’t read Polish characters yet — check ą, ę, ł, ż in product names.**
  - Before: Tento iPhone zatiaľ nevie čítať poľské znaky — skontroluj ą, ę, ł, ż v názvoch produktov.
  - After: Tento iPhone zatiaľ nevie čítať poľské znaky — skontrolujte ą, ę, ł, ż v názvoch produktov.
  - Restore formal/plural address used by existing Slovak instructions and earlier receipt messages; change only the inconsistent pronouns/verb endings.

### sr-Latn (2)

- **Localizable: Refund**
  - Before: Povrat
  - After: Povraćaj novca
  - Finance terminology — Use the standard explicit Serbian retail/banking term for refund (povraćaj novca), rather than ambiguous Povrat.
- **Localizable: Too many open drafts**
  - Before: Previše otvorenih skica
  - After: Previše otvorenih nacrta
  - Use nacrti for drafts consistently with the draft-expiry and draft-confirmation messages; skice suggests sketches.

### sv (1)

- **Localizable: Back to text**
  - Before: Tillbake till texten
  - After: Tillbaka till texten
  - Correct the Norwegian spelling Tillbake to Swedish Tillbaka.

### sw (2)

- **Localizable: Items and total differ by %@. Go back and fix the text.**
  - Before: Vipengee na jumla kuu zinatofautiana kwa %@. Rudi nyuma na usahihisha maandishi.
  - After: Vipengee na jumla kuu zinatofautiana kwa %@. Rudi nyuma na usahihishe maandishi.
  - Correct the imperative/subjunctive verb ending usahihisha to usahihishe after na.
- **Localizable: Shop or NIP changed, so these matches no longer apply. Save without a link, or go back and read the text again.**
  - Before: Duka au NIP vimebadilika, hivyo vipengee vilivyooana havitumiki tena. Hifadhi bila kiungo, au rudi nyuma na usome maandishi tena.
  - After: Duka au NIP vimebadilika, hivyo miamala hii inayolingana haitumiki tena. Hifadhi bila kiungo, au rudi nyuma na usome maandishi tena.
  - Finance terminology — The matches are candidate bank transactions (miamala), not receipt items (vipengee); preserves the matching-transaction terminology.

### tr (5)

- **Localizable: Scan the receipt again to start from the current version.**
  - Before: Geçerli sürümden başlamak için fişi yeniden tara.
  - After: Geçerli sürümden başlamak için fişi yeniden tarayın.
  - Restore formal/plural address used by existing Turkish instructions and earlier receipt messages; change only the inconsistent verb endings.
- **Localizable: Shop or NIP changed, so these matches no longer apply. Save without a link, or go back and read the text again.**
  - Before: Mağaza veya NIP değiştiği için bu eşleşmeler artık geçerli değil. Bağlantı olmadan kaydet veya geri dönüp metni yeniden oku.
  - After: Mağaza veya NIP değiştiği için bu eşleşmeler artık geçerli değil. Bağlantı olmadan kaydedin veya geri dönüp metni yeniden okuyun.
  - Restore formal/plural address used by existing Turkish instructions and earlier receipt messages; change only the inconsistent verb endings.
- **Localizable: Some item amounts don’t add up. Go back and fix the text.**
  - Before: Bazı ürünlerin tutarları toplamla uyuşmuyor. Geri dön ve metni düzelt.
  - After: Bazı ürünlerin tutarları toplamla uyuşmuyor. Geri dönün ve metni düzeltin.
  - Restore formal/plural address used by existing Turkish instructions and earlier receipt messages; change only the inconsistent verb endings.
- **Localizable: The receipt is too large for the server. Shorten the text and read it again.**
  - Before: Fiş sunucu için çok büyük. Metni kısalt ve yeniden oku.
  - After: Fiş sunucu için çok büyük. Metni kısaltın ve yeniden okuyun.
  - Restore formal/plural address used by existing Turkish instructions and earlier receipt messages; change only the inconsistent verb endings.
- **Localizable: This iPhone can’t read Polish characters yet — check ą, ę, ł, ż in product names.**
  - Before: Bu iPhone henüz Lehçe karakterleri okuyamıyor — ürün adlarındaki ą, ę, ł, ż karakterlerini kontrol et.
  - After: Bu iPhone henüz Lehçe karakterleri okuyamıyor — ürün adlarındaki ą, ę, ł, ż karakterlerini kontrol edin.
  - Restore formal/plural address used by existing Turkish instructions and earlier receipt messages; change only the inconsistent verb endings.

### uk (1)

- **Localizable: Transaction already has a receipt**
  - Before: До цієї транзакції вже додано чек
  - After: До цієї операції вже додано чек
  - Finance terminology — Use операція consistently with Bank transaction and all matching-transaction instructions, rather than changing the same entity to транзакція.

### zh-Hans (6)

- **InfoPlist: NSCameraUsageDescription**
  - Before: Vesta 使用相机扫描小票。文本在你的 iPhone 上读取；照片不会存储或上传。
  - After: Vesta 使用相机扫描收据。文本在你的 iPhone 上读取；照片不会存储或上传。
  - Finance terminology — Use 收据 consistently with the receipt named in the scan UI rather than switching to 小票 in the camera permission.
- **Localizable: Scan the receipt again to start from the current version.**
  - Before: 重新扫描小票，从当前版本开始。
  - After: 重新扫描收据，从当前版本开始。
  - Finance terminology — Use 收据 consistently for the same receipt named 收据 throughout the scan/save UI; avoids switching the document term to 小票 in errors.
- **Localizable: The receipt is too large for the server. Shorten the text and read it again.**
  - Before: 小票过大，服务器无法处理。请缩短文本后重新识别。
  - After: 收据过大，服务器无法处理。请缩短文本后重新识别。
  - Finance terminology — Use 收据 consistently for the same receipt named 收据 throughout the scan/save UI; avoids switching the document term to 小票 in errors.
- **Localizable: The server could not accept this receipt.**
  - Before: 服务器无法接受这张小票。
  - After: 服务器无法接受这张收据。
  - Finance terminology — Use 收据 consistently for the same receipt named 收据 throughout the scan/save UI; avoids switching the document term to 小票 in errors.
- **Localizable: The server owner has not enabled receipts yet.**
  - Before: 服务器所有者尚未启用小票功能。
  - After: 服务器所有者尚未启用收据功能。
  - Finance terminology — Use 收据 consistently for the same receipt named 收据 throughout the scan/save UI; avoids switching the document term to 小票 in errors.
- **Localizable: Transaction already has a receipt**
  - Before: 该交易已有小票
  - After: 该交易已有收据
  - Finance terminology — Use 收据 consistently for the same receipt named 收据 throughout the scan/save UI; avoids switching the document term to 小票 in errors.

## Reviewed without corrections

bn, da, fil, hi, hr, it, ms, nb, nl, pt-BR, sq, th, vi, zh-Hant.

## Validation

- Both JSON catalogs parse; only the recorded string values change.
- Every receipt key retains all 44 translations; the camera purpose retains English plus 44 translations.
- Placeholder signatures and all catalog metadata/structures are preserved.
- No changes to receipt, total, payment, card, cash, refund, discount, deposit, or VAT terminology beyond those explicitly marked above. VAT, discount, and deposit have no standalone UI keys in this receipt flow.
