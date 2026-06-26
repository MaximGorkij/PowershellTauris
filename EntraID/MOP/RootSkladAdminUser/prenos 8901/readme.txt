
======================================================================
OpenOffice 4.1.15 ČítajMa
======================================================================


Pre najnovšie verziu súboru readme navštívte http://www.openoffice.org/welcome/readme.html

Tento súbor obsahuje dôležité informácie o tomto programe. Prečítajte si, prosím, tieto informácie skôr než začnete pracovať.

Komunita Apache OpenOffice, zodpovedná za vývoj tohto produktu, si vás dovoľuje pozvať, aby ste sa zúčastňovali v projekte ako člen komunity. Ako nový používateľ sa môžete pozrieť na stránku komunity OpenOffice s užitočnými informáciami na adrese http://openoffice.apache.org

Taktiež si prečítajte nižšie uvedené informácie o tom ako sa zapojiť do projektu Apache OpenOffice.

Je OpenOffice skutočne zadarmo pre každého používateľa? 
----------------------------------------------------------------------

OpenOffice je zadarmo pre každého. Môžete si zobrať túto kópiu OpenOffice a nainštalovať ju na ľubovoľný počet počítačov a používať ju na ľubovoľný účel (toto zahŕňa podniky, vlády, verejnú správu a aj školy). Pre ďalšie informácie si prečítajte text licencie dodaný spolu s OpenOffice alebo http://www.openoffice.org/license.html

Prečo je OpenOffice zadarmo pre každého používateľa?
----------------------------------------------------------------------

Dnes môžete používať zadarmo túto kópiu OpenOffice, preto lebo individuálny prispievatelia a firemný sponzori navrhli, vyvinuli, testovali, preložili, zdokumentovali, podporovali, marketovali a pomohli v mnohých ďalších ohľadoch urobiť OpenOffice to, čím dnes je - svetovým lídrom v oblasti open-source kancelárskeho softvéru.

Ak si ceníte ich námahu a radi by ste zaistili to, že Apache OpenOffice bude fungovať aj v budúcnosti, zvážte prosím vaše prispievanie do projektu - viď http://openoffice.apache.org/get-involved.html pre detaily o čase potrebnom na prispievanie a http://www.apache.org/foundation/contributing.html pre detaily o dotácii. Každý má čím prispieť.

----------------------------------------------------------------------
Poznámky k inštalácii
----------------------------------------------------------------------

OpenOffice pre plnú funkčnosť vyžaduje aktuálnu verziu JAVA; JAVA môže byť stiahnutá z http://java.com

Systémové požiadavky
----------------------------------------------------------------------

* Microsoft Windows XP, Vista, Windows 7 alebo Windows 8
* Pentium III alebo novší procesor
* 256 MB RAM (odporúčané 512 MB RAM)
* Až do 1,5 GB dostupného diskového priestoru
* rozlíšenie 1024x768 (odporúčané je vyššie rozlíšenie), aspoň 256 farieb

Registrácia OpenOffice ako východzej aplikácie pre formáty Microsoft Office môže byť vynútená alebo potlačená pomocou použitia nasledovných prepínačov z príkazového riadka pri spustení inštalátora:

* /msoreg=1 vynúti registráciu OpenOffice ako východzej aplikácie pre formáty Microsoft Office.
* /msoreg=0 potlačí registráciu OpenOffice ako východzej aplikácie pre formáty Microsoft Office.

V prípade že vykonávate inštaláciu pre správca s použitím setup /a, musíte sa ubezpečiť, že súbor msvcr100.dll je nainštalovaný v systéme. Tento súbor je potrebný preto, aby bolo možné spustiť OpenOffice po inštálácii pre správcu. Tento súbor môžete získať z http://www.microsoft.com/en-us/download/details.aspx?id=5555

Nezabudnite, že na inštaláciu budete potrebovať práva správcu systému.

Skontrolujte dostatok voľného miesta v adresári pre dočasné dáta a či máte práva pre čítanie, zapisovanie a spúšťanie. Pred začiatkom inštalácie skončite všetky ostatné programy.

----------------------------------------------------------------------
Problémy počas štartu programu
----------------------------------------------------------------------

Problémy pri spúšťaní OpenOffice (napr. zmrznutie aplikácie) a taktiež problémy s obrazovkou sú často spôsobované ovládačom grafickej karty. V prípade výskytu týchto problémov aktualizujte váš ovládač grafickej karty alebo použite ovládač, ktorý bolo dodaný spolu s vašim operačným systémom. Ťažkosti so zobrazovaním 3D objektov môžu byť často vyriešené deaktivovaním možnosti "Použiť OpenGL" v ponuke 'Nástroje - Možnosti - OpenOffice - Zobraziť - 3D zobrazenie'.

----------------------------------------------------------------------
ALPS/Synaptics notebook touchpady vo Windows
----------------------------------------------------------------------

Kvôli problému s ovládačmi Windows nemôžete posúvať dokumenty v OpenOffice posúvaním prsta po touchpade ALPS/Synaptics.

Posúvania touchpadom zapnete pridaním nasledujúcich riadkov do konfiguračného súboru "C:\Program Files\Synaptics\SynTP\SynTPEnh.ini" a reštartujte váš počítač:

[OpenOffice]

FC = "SALFRAME"

SF = 0x10000000

SF |= 0x00004000

Umiestnenie konfiguračného súboru sa môže líšiť v závislosti od verzie Windows.

----------------------------------------------------------------------
Klávesové skratky
----------------------------------------------------------------------

V OpenOffice je možné používať iba skratky (kombinácie kláves), ktoré nepoužíva operačný systém. Ak skratka v OpenOffice nefunguje podľa popisu v Pomocníkovi OpenOffice, skontrolujte, či už skratku nepoužíva operačný systém. Takýto konflikt vyriešite zmenou skratky, ktorú používa operačný systém alebo môžete zmeniť takmer ktorúkoľvek skratku v OpenOffice. Viac informácií na túto tému vám poskytne Pomocník OpenOffice alebo dokumentácia k vášmu operačnému systému.

----------------------------------------------------------------------
Problémy pri posielaní dokumentov formou emailu z OpenOffice
----------------------------------------------------------------------

Pri odosielaní dokumentov pomocou 'Súbor - Odoslať - Dokument e-mailom' alebo 'Dokument ako prílohu v PDF' sa môžu vyskytnúť problémy (program spadne alebo prestane reagovať). Príčinou je „Mapi“ (Messaging Application Programming Interface) systému Windows, ktoré v niektorých verziách spôsobuje problémy. Bohužiaľ sa nepodarilo vysledovať problém k určitej verzii súboru. Bližšie informácie zistíte na http://www.microsoft.com vyhľadaním "mapi dll" v Microsoft Knowledge Base.

----------------------------------------------------------------------
Dôležité poznámky k prístupnosti
----------------------------------------------------------------------

Pre viac informácií o funkciách prístupnosti v OpenOffice navštívte http://www.openoffice.org/access/

----------------------------------------------------------------------
Používateľská podpora
----------------------------------------------------------------------

Hlavná stránka podpory http://support.openoffice.org/ ponúka rôzne možnosti pomoci s OpenOffice. Vaša otázka už mohla by zodpovedaná - pozrite sa na komunitné fórum na http://forum.openoffice.org alebo prehľadajte archívy mailing listou 'users@openoffice.apache.org' na http://openoffice.apache.org/mailing-lists.html. Prípadne môžete poslať vaše otázky na users@openoffice.apache.org. Ako sa prihlásiť do mailing listu (aby ste mohli dostať odpoveď emailom) je vysvetlené na stránke: http://openoffice.apache.org/mailing-lists.html.

Taktiež si pozrite sekciu často kladených otázok FAQ na http://wiki.openoffice.org/wiki/Documentation/FAQ.

----------------------------------------------------------------------
Oznamovanie chýb & problémov
----------------------------------------------------------------------

OpenOffice Webové stránky obsahujú BugZilla, náš mechanizmus pre hlásenie, sledovanie a riešenie chýb a otázok. Podporujeme všetkých užívateľov v tom, aby sa cítili príjemne a užitočne v hlásení chýb, ktoré sa môžu objaviť na podobnej platforme ako je vaša. Aktívne hlásenie chýb je jeden z najviac dôležitých spôsobov prispievania, ktoré môže komunita užívateľov spraviť pre nasledujúci vývoj a vylepšenie balíka.

----------------------------------------------------------------------
Ako sa zapojiť
----------------------------------------------------------------------

Komunita OpenOffice bude mať prospech z vašej aktívnej účasti na vývoji tohto významného open source projektu.

Ako používateľ ste významnou súčasťou vývoja balíka a radi by sme vás podporili pri rozvíjaní ďalších aktivít s výhľadom na získanie dlhodobého prispievateľa do komunity. Pozrite sa, prosím, na používateľské stránky na adrese http://openoffice.apache.org/get-involved.html

Ako začať
----------------------------------------------------------------------

Najlepší spôsob ako začať prispievať je prihlásiť sa na jeden alebo viac mailing listov, chvíľu sledovať, a postupne prechádzať archív správ aby ste sa zoznámili s mnohými témami od októbra 2000, keď bol vydaný zdrojový kód OpenOffice. Keď sa na to budete cítiť, všetko, čo potrebujete je poslať email, v ktorom sa predstavíte a skočiť do toho.

Prihlásiť sa
----------------------------------------------------------------------

Tu je zopár OpenOffice mailing listov, do ktorých sa môžete prihlásiť na http://openoffice.apache.org/mailing-lists.html

* Novinky: announce@openoffice.apache.org *odporúča sa všetkým používateľom* (nízka aktivita)
* Hlavné používateľské fórum: users@openoffice.apache.org *ľahká cesta ako sa zaseknúť v diskusii* (vysoká aktivita)
* Všeobecné diskusie a diskusie o vývoji projektu sú na: dev@openoffice.apache.org (vysoká aktivita)

Pridajte sa ku projektu
----------------------------------------------------------------------

Môžete sa stať výraznou posilou vývojárskeho tímu a to i v prípade, že máte len menšie skúsenosti s vývojom softvéru. Áno, vy!

Na http://openoffice.apache.org/get-involved.html nájdete prehľad, kde môžete začať s lokalizáciou, zabezpečovaním kvality QA, užívateľskou podporou, prípadne programovaním hlavných súčastí. Ak nie ste programátor, môžete pomôct, napr. s dokumentáciou alebo marketingom. OpenOffice marketing je aplikovanie partizánskych aj tradičných komerčných techník v obchodovaní s open source softvérom a robíme to naprieč rôznym jazykom a kultúrym bariéram, a aj vy môžete pomocť šíriť tento kancelársky balík iba tým, že poviete o ňom svojím priateľom.

Môžete pomôcť pripojením sa na marketingový mailing list marketing@openoffice.apache.org, kde sa môžete stať kontaktom pre vecnú komunikáciu s tlačou, médiami, vládnymi agentúrami, konzultantmi, školami, používateľmi linuxu LUG a vývojáromi vo vašej krajine a lokálnej komunite.

Dúfame, že sa vám bude práca s novým OpenOffice 4.1.15 páčiť, a že sa k nám pridáte.

Komunita Apache OpenOffice