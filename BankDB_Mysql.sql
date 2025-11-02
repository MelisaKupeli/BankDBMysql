-- BankDB_mysql.sql
-- SQL Server sürümünden MySQL sürümüne çevrilmiştir.

DROP DATABASE IF EXISTS BankDb;
CREATE DATABASE BankDb;
USE BankDb;

-- Tablolar
DROP TABLE IF EXISTS CreditCards;
DROP TABLE IF EXISTS BankCards;
DROP TABLE IF EXISTS CustomerAccountInformation;
DROP TABLE IF EXISTS CustomerInformation;

CREATE TABLE CustomerInformation (
  Id INT AUTO_INCREMENT PRIMARY KEY,
  Identification VARCHAR(11) NOT NULL,
  NameSurname VARCHAR(100) NOT NULL,
  PlaceOfBirth VARCHAR(30) NOT NULL,
  DateOfBirth DATE NOT NULL,
  RiskLimit INT NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE CustomerAccountInformation (
  AccountId INT AUTO_INCREMENT PRIMARY KEY,
  CustomerId INT NOT NULL,
  AccountName VARCHAR(50) NOT NULL,
  AccountCode VARCHAR(34) NOT NULL,
  OpeningDate DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  ClosingDate DATETIME DEFAULT NULL,
  CardStatus TINYINT DEFAULT 1,
  FOREIGN KEY (CustomerId) REFERENCES CustomerInformation(Id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE CreditCards (
  CCardId INT AUTO_INCREMENT PRIMARY KEY,
  CustomerId INT NOT NULL,
  CreditCard VARCHAR(34),
  `Limit` DECIMAL(18,2) NOT NULL,
  CardStatus TINYINT DEFAULT 1,
  TransferDate DATETIME DEFAULT NULL,
  OpeningDate DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  ClosingDate DATETIME DEFAULT NULL,
  `Comment` VARCHAR(100) DEFAULT NULL,
  FOREIGN KEY (CustomerId) REFERENCES CustomerInformation(Id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE BankCards (
  BCardId INT AUTO_INCREMENT PRIMARY KEY,
  CustomerId INT NOT NULL,
  BankCard VARCHAR(34),
  `Limit` DECIMAL(18,2) NOT NULL,
  CardStatus TINYINT DEFAULT 1,
  TransferDate DATETIME DEFAULT NULL,
  OpeningDate DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  ClosingDate DATETIME DEFAULT NULL,
  `Comment` VARCHAR(100) DEFAULT NULL,
  FOREIGN KEY (CustomerId) REFERENCES CustomerInformation(Id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Temizlik (safely)
TRUNCATE TABLE CreditCards;
TRUNCATE TABLE BankCards;
TRUNCATE TABLE CustomerAccountInformation;
TRUNCATE TABLE CustomerInformation;

-- Basit veri ekleme örneği (orijinal dosyada vardı)
INSERT INTO CustomerInformation (Identification, NameSurname, PlaceOfBirth, DateOfBirth, RiskLimit)
VALUES ('11111111111', 'Gün Gören', 'Eskişehir', '1993-02-01', 10000);

INSERT INTO CustomerAccountInformation (CustomerId, AccountName, AccountCode, CardStatus)
VALUES (1, 'Vadesiz Anadolu', 'TR 01 1234 1546 4578 8999', 1);

-- Trigger: bir müşteri için maksimum kredi kartı sayısını 2 ile sınırla
DELIMITER $$
CREATE TRIGGER trg_CreditCards_before_insert
BEFORE INSERT ON CreditCards
FOR EACH ROW
BEGIN
  DECLARE cnt INT;
  SELECT COUNT(*) INTO cnt FROM CreditCards WHERE CustomerId = NEW.CustomerId AND (ClosingDate IS NULL OR ClosingDate > NOW());
  IF cnt >= 2 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Maksimum oluşturulabilir kredi kartı sayısı dolmuştur.';
  END IF;
END$$
DELIMITER ;

-- Trigger: bir müşteri için maksimum banka kartı sayısını 1 ile sınırla
DELIMITER $$
CREATE TRIGGER trg_BankCards_before_insert
BEFORE INSERT ON BankCards
FOR EACH ROW
BEGIN
  DECLARE cnt INT;
  SELECT COUNT(*) INTO cnt FROM BankCards WHERE CustomerId = NEW.CustomerId AND (ClosingDate IS NULL OR ClosingDate > NOW());
  IF cnt >= 1 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Mevcut bir banka kartınız zaten bulunmakta.';
  END IF;
END$$
DELIMITER ;

-- Trigger: hesap eklenince; varsa önceki hesap kartını pasif yap ve yeni hesabı aktif bırak
DELIMITER $$
CREATE TRIGGER trg_Account_after_insert
AFTER INSERT ON CustomerAccountInformation
FOR EACH ROW
BEGIN
  DECLARE cnt INT;
  SELECT COUNT(*) INTO cnt FROM CustomerAccountInformation WHERE CustomerId = NEW.CustomerId;
  IF cnt > 1 THEN
    -- Eski hesapların CardStatus'ını 0 (pasif) yap
    UPDATE CustomerAccountInformation
      SET CardStatus = 0
      WHERE CustomerId = NEW.CustomerId AND AccountId <> NEW.AccountId;
    -- Yeni kaydın CardStatus'ı zaten varsayılan 1
  END IF;
END$$
DELIMITER ;

-- Para transferi prosedürleri (MySQL sürümü)
-- sp_MoneyTransferCreditC: kredi kartından harcama (gönderenden düşer, alıcıya eklenebilir)
DELIMITER $$
CREATE PROCEDURE sp_MoneyTransferCreditC (
  IN p_Comment VARCHAR(100),
  IN p_Purchaser VARCHAR(34),
  IN p_Sender VARCHAR(34),
  IN p_Amount DECIMAL(18,2),
  OUT p_retVal INT
)
BEGIN
  DECLARE v_limit DECIMAL(18,2);
  DECLARE v_senderId INT;
  DECLARE v_purchaserId INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    SET p_retVal = -2; -- işlem hatası
  END;

  SELECT `Limit`, CustomerId INTO v_limit, v_senderId FROM CreditCards WHERE CreditCard = p_Sender LIMIT 1;
  IF v_limit IS NULL THEN
    SET p_retVal = -3; -- gönderici kart bulunamadı
    LEAVE proc_end;
  END IF;

  IF v_limit < p_Amount THEN
    SET p_retVal = -1; -- bakiye yetersiz
    LEAVE proc_end;
  END IF;

  START TRANSACTION;
    UPDATE CreditCards SET `Limit` = `Limit` - p_Amount, TransferDate = NOW() WHERE CreditCard = p_Sender;
    IF p_Purchaser IS NOT NULL AND p_Purchaser <> 'Null' THEN
      SELECT CustomerId INTO v_purchaserId FROM CreditCards WHERE CreditCard = p_Purchaser LIMIT 1;
      IF v_purchaserId IS NOT NULL THEN
        UPDATE CreditCards SET `Limit` = `Limit` + p_Amount WHERE CreditCard = p_Purchaser;
      END IF;
    END IF;
  COMMIT;
  SET p_retVal = 200;
  proc_end: BEGIN END;
END$$
DELIMITER ;

-- sp_MoneyTransferBankC: banka kartı ile para çekme / yatırma
DELIMITER $$
CREATE PROCEDURE sp_MoneyTransferBankC (
  IN p_Comment VARCHAR(100),
  IN p_Purchaser VARCHAR(34),
  IN p_Sender VARCHAR(34),
  IN p_Amount DECIMAL(18,2),
  OUT p_retVal INT
)
BEGIN
  DECLARE v_limit DECIMAL(18,2);
  DECLARE v_senderId INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    SET p_retVal = -2;
  END;

  SELECT `Limit`, CustomerId INTO v_limit, v_senderId FROM BankCards WHERE BankCard = p_Sender LIMIT 1;
  IF v_limit IS NULL THEN
    SET p_retVal = -3;
    LEAVE proc_end2;
  END IF;

  IF v_limit < p_Amount THEN
    SET p_retVal = -1;
    LEAVE proc_end2;
  END IF;

  START TRANSACTION;
    UPDATE BankCards SET `Limit` = `Limit` - p_Amount, TransferDate = NOW() WHERE BankCard = p_Sender;
    IF p_Purchaser IS NOT NULL AND p_Purchaser <> 'Null' THEN
      UPDATE BankCards SET `Limit` = `Limit` + p_Amount WHERE BankCard = p_Purchaser;
    END IF;
  COMMIT;
  SET p_retVal = 200;
  proc_end2: BEGIN END;
END$$
DELIMITER ;

-- Basit "read" prosedürü (birden fazla SELECT döndürebilir)
DELIMITER $$
CREATE PROCEDURE sp_Read()
BEGIN
  SELECT * FROM CustomerInformation;
  SELECT * FROM CustomerAccountInformation;
  SELECT * FROM BankCards;
  SELECT * FROM CreditCards;
END$$
DELIMITER ;

-- sp_Create: bazı özet istatistikler (örnek olarak)
DELIMITER $$
CREATE PROCEDURE sp_Create()
BEGIN
  SELECT Id, COUNT(Id) AS CountId, COALESCE(MIN(CreatedAt), CURRENT_TIMESTAMP) AS FirstCreate
    FROM CustomerInformation GROUP BY Id ORDER BY CountId DESC;
  SELECT CustomerId, COUNT(CustomerId) AS CountAccounts, COALESCE(MIN(OpeningDate), CURRENT_TIMESTAMP) AS FirstOpening
    FROM CustomerAccountInformation GROUP BY CustomerId ORDER BY CountAccounts DESC;
  SELECT CustomerId, COUNT(CustomerId) AS CountBankCards, COALESCE(MIN(OpeningDate), CURRENT_TIMESTAMP) AS FirstOpening
    FROM BankCards GROUP BY CustomerId ORDER BY CountBankCards DESC;
  SELECT CustomerId, COUNT(CustomerId) AS CountCreditCards, COALESCE(MIN(OpeningDate), CURRENT_TIMESTAMP) AS FirstOpening
    FROM CreditCards GROUP BY CustomerId ORDER BY CountCreditCards DESC;
END$$
DELIMITER ;

-- sp_Delete: silme örneği (Account, BankCard, CreditCard için verilen id ile)
DELIMITER $$
CREATE PROCEDURE sp_Delete(IN p_DeleteId INT)
BEGIN
  START TRANSACTION;
    DELETE FROM CustomerAccountInformation WHERE AccountId = p_DeleteId;
    DELETE FROM BankCards WHERE BCardId = p_DeleteId;
    DELETE FROM CreditCards WHERE CCardId = p_DeleteId;
  COMMIT;
END$$
DELIMITER ;

-- sp_Update: basit kart güncelleme (örnek)
DELIMITER $$
CREATE PROCEDURE sp_Update (
  IN p_UpdateId INT,
  IN p_Limit DECIMAL(18,2),
  IN p_CardStatus TINYINT,
  IN p_TransferDate DATETIME,
  IN p_Comment VARCHAR(100)
)
BEGIN
  UPDATE BankCards
    SET `Limit` = p_Limit, CardStatus = p_CardStatus, TransferDate = p_TransferDate, `Comment` = p_Comment
    WHERE BCardId = p_UpdateId;
  UPDATE CreditCards
    SET `Limit` = p_Limit, CardStatus = p_CardStatus, TransferDate = p_TransferDate, `Comment` = p_Comment
    WHERE CCardId = p_UpdateId;
END$$
DELIMITER ;

-- Trigger'lar ve prosedürler eklendi, şimdi örnek eklemeler ve test çağrıları:

-- Örnek BankCard / CreditCard ekleme (kısıtlamalar trigger tarafından kontrol edilecek)
INSERT INTO BankCards (CustomerId, BankCard, `Limit`, `Comment`) VALUES (1, '1234 9876 5464 5489', 10000.00, 'Vadesiz Anadolu kartı');
INSERT INTO CreditCards (CustomerId, CreditCard, `Limit`) VALUES (1, '1234 9876 5464 5488', 5000.00);
INSERT INTO CreditCards (CustomerId, CreditCard, `Limit`) VALUES (1, '1234 9876 5464 5487', 3000.00);

-- Örnek prosedür çağrıları (MySQL tarzı OUT parametre kullanımı)
-- CREDIT TRANSFER EXAMPLE
SET @ret = 0;
CALL sp_MoneyTransferCreditC('Yaz Tatili', NULL, '1234 9876 5464 5488', 700.25, @ret);
SELECT @ret;

-- BANK TRANSFER EXAMPLE
SET @ret = 0;
CALL sp_MoneyTransferBankC('Para Yatırıldı', '1234 9876 5464 5489', '1234 9876 5464 5489', 1500.00, @ret);
SELECT @ret;

-- Basit select'ler
SELECT * FROM CustomerInformation;
SELECT * FROM CustomerAccountInformation;
SELECT * FROM BankCards;
SELECT * FROM CreditCards;
