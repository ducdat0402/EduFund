/* =====================================================================
   EduFund - Database schema v2 (SQL Server 2019+ / Azure SQL Database)

   Cach chay:
   - SQL Server local / Docker: tao database roi chay file nay trong do
         CREATE DATABASE EduFund;
         GO
         USE EduFund;
         GO
   - Azure SQL: ket noi vao database trong, chay thang file nay.

   File chay lai duoc (re-runnable): phan 0 xoa cac bang cu cua 6 schema.

   Schema (nhom bang trong diagram):
     iam  - nguoi dung, vai tro
     edu  - truong, lop, cong dan (mock), hoc sinh, nhap hoc, ho gia dinh
     fin  - quy, tai khoan giao duc, giao dich, top-up, phi, thanh toan, CPF
     fas  - chinh sach, khoang thu nhap, tier, don gia dinh, ket qua tung con, SBFAS, ML
     ai   - kho tri thuc RAG, chatbot
     aud  - audit log, simulate, log job nen

   Thay doi so voi v1:
   - Xoa iam.Permission, iam.RolePermission (quyen theo role, viet trong code);
     tach role School thanh SCHOOL_STAFF va SCHOOL_APPROVER; them AppUser.CanSimulate.
   - fin.FeeItem doi thanh fin.FeeComponent va gan voi edu.Class (khong gan School).
   - Xoa fin.BankAccount va cot RefundBankAccountId. Them fin.CpfAccount, fin.CpfTransfer:
     khi tai khoan dong, so du chuyen sang CPF.
   - Them fin.Fund (quy top-up cua chinh phu).
   - fin.EducationAccount gan voi edu.Citizen (khong gan Student), them trang thai CLOSING.
   - Them edu.StudentEnrolment (lich su nhap hoc, chuyen truong); edu.Student bo SchoolId, ClassId.
   - Them edu.CitizenFeedImport (file cong dan tu Bo Noi vu, xu ly delta).
   - Them fas.IncomeBand; tier va snapshot thu nhap dung khoang (band) thay vi so tien.
   - fin.TopUpRule: them TriggerType, BalanceCap, RequireApproval; fin.TopUpBatch: them FundId, duyet.
   - fin.FeeTypePayableRule: cau hinh loai phi nao tra duoc bang tai khoan giao duc theo thoi gian.
   - fin.Payment: them Channel (CARD, PAYNOW, NETS) va IdempotencyKey.
   - fin.StudentCharge: them trang thai OVERDUE, BAD_DEBT.
   - fas.ChildResult: chi cho phep 1 ket qua GRANTED/APPROVED cho moi con (MOE FAS hoac SBFAS).
   - fas.RiskAssessment: them SuggestedAmount (de xuat cho SBFAS).
   - AcademicYear giu dang cot so (smallint), khong tao bang rieng.

   Ghi chu thiet ke:
   - Du lieu cong dan, thu nhap, CPF, cong thanh toan la MOCK. Khong luu so the/STK.
   - So du (fin.EducationAccount.Balance) la ban sao; nguon su that la
     fin.AccountTransaction (so cai chi them, khong sua).
   ===================================================================== */
SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------
   0. Don dep (xoa FK roi xoa bang) de co the chay lai
   --------------------------------------------------------------------- */
DECLARE @sql nvarchar(max) = N'';
SELECT @sql += N'ALTER TABLE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name)
             + N' DROP CONSTRAINT ' + QUOTENAME(f.name) + N';'
FROM sys.foreign_keys f
JOIN sys.tables  t ON f.parent_object_id = t.object_id
JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE s.name IN (N'iam', N'edu', N'fin', N'fas', N'ai', N'aud');
EXEC sys.sp_executesql @sql;

SET @sql = N'';
SELECT @sql += N'DROP TABLE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + N';'
FROM sys.tables t
JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE s.name IN (N'iam', N'edu', N'fin', N'fas', N'ai', N'aud');
EXEC sys.sp_executesql @sql;
GO

IF SCHEMA_ID(N'iam') IS NULL EXEC(N'CREATE SCHEMA iam');
IF SCHEMA_ID(N'edu') IS NULL EXEC(N'CREATE SCHEMA edu');
IF SCHEMA_ID(N'fin') IS NULL EXEC(N'CREATE SCHEMA fin');
IF SCHEMA_ID(N'fas') IS NULL EXEC(N'CREATE SCHEMA fas');
IF SCHEMA_ID(N'ai')  IS NULL EXEC(N'CREATE SCHEMA ai');
IF SCHEMA_ID(N'aud') IS NULL EXEC(N'CREATE SCHEMA aud');
GO

/* =====================================================================
   1. IAM - vai tro (quyen chi tiet viet trong code theo tung role)
   ===================================================================== */
CREATE TABLE iam.AppRole (
    RoleId   tinyint       NOT NULL CONSTRAINT PK_AppRole PRIMARY KEY,
    Code     varchar(20)   NOT NULL CONSTRAINT UQ_AppRole_Code UNIQUE,   -- MOE_HQ, SCHOOL_STAFF, SCHOOL_APPROVER, PARENT
    Name     nvarchar(100) NOT NULL
);

/* =====================================================================
   2. EDU - truong, lop, cong dan (mock)
   ===================================================================== */
CREATE TABLE edu.School (
    SchoolId  int IDENTITY(1,1) NOT NULL CONSTRAINT PK_School PRIMARY KEY,
    Code      varchar(20)   NOT NULL CONSTRAINT UQ_School_Code UNIQUE,
    Name      nvarchar(200) NOT NULL,
    HasSbfas  bit           NOT NULL CONSTRAINT DF_School_HasSbfas DEFAULT 1,   -- truong co SBFAS hay khong
    IsActive  bit           NOT NULL CONSTRAINT DF_School_IsActive DEFAULT 1
);

CREATE TABLE edu.Level (
    LevelId   tinyint       NOT NULL CONSTRAINT PK_Level PRIMARY KEY,
    Code      varchar(10)   NOT NULL CONSTRAINT UQ_Level_Code UNIQUE,           -- P1..P6, S1..S5
    Name      nvarchar(50)  NOT NULL,
    Stage     varchar(15)   NOT NULL CONSTRAINT CK_Level_Stage CHECK (Stage IN ('PRIMARY','SECONDARY')),
    SortOrder tinyint       NOT NULL
);

-- Lop hoc theo nam hoc (AcademicYear la cot so, khong co bang rieng)
CREATE TABLE edu.Class (
    ClassId      int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Class PRIMARY KEY,
    SchoolId     int          NOT NULL CONSTRAINT FK_Class_School REFERENCES edu.School(SchoolId),
    LevelId      tinyint      NOT NULL CONSTRAINT FK_Class_Level  REFERENCES edu.Level(LevelId),
    Name         nvarchar(50) NOT NULL,                                           -- ten lop tu do, vd 3A, Discipline
    AcademicYear smallint     NOT NULL,
    CONSTRAINT UQ_Class UNIQUE (SchoolId, LevelId, Name, AcademicYear)
);

-- Moi lan nhan file cong dan tu Bo Noi vu (toan bo cong dan 7-16 tuoi), xu ly delta
CREATE TABLE edu.CitizenFeedImport (
    ImportId       bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_CitizenFeedImport PRIMARY KEY,
    FileName       nvarchar(260) NOT NULL,
    ReceivedAt     datetime2(0)  NOT NULL CONSTRAINT DF_FeedImport_Received DEFAULT SYSUTCDATETIME(),
    Status         varchar(12)   NOT NULL CONSTRAINT CK_FeedImport_Status
                                 CHECK (Status IN ('RECEIVED','PROCESSING','COMPLETED','FAILED')),
    TotalRecords   int           NOT NULL CONSTRAINT DF_FeedImport_Total   DEFAULT 0,
    NewCount       int           NOT NULL CONSTRAINT DF_FeedImport_New     DEFAULT 0,
    ChangedCount   int           NOT NULL CONSTRAINT DF_FeedImport_Changed DEFAULT 0,   -- vd doi quoc tich
    RemovedCount   int           NOT NULL CONSTRAINT DF_FeedImport_Removed DEFAULT 0,
    ProcessedAt    datetime2(0)  NULL,
    ErrorMessage   nvarchar(500) NULL
);

-- Danh ba cong dan GIA LAP (lay tu file Bo Noi vu). NationalId la ma gia. Song tich coi nhu SINGAPORE_CITIZEN.
CREATE TABLE edu.Citizen (
    CitizenId   bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Citizen PRIMARY KEY,
    NationalId  varchar(20)   NOT NULL CONSTRAINT UQ_Citizen_NationalId UNIQUE,
    FullName    nvarchar(200) NOT NULL,
    DateOfBirth date          NOT NULL,
    Nationality varchar(20)   NOT NULL CONSTRAINT CK_Citizen_Nationality
                              CHECK (Nationality IN ('SINGAPORE_CITIZEN','PR','OTHER')),
    LastImportId bigint       NULL CONSTRAINT FK_Citizen_Import REFERENCES edu.CitizenFeedImport(ImportId),
    CreatedAt   datetime2(0)  NOT NULL CONSTRAINT DF_Citizen_CreatedAt DEFAULT SYSUTCDATETIME()
);

/* =====================================================================
   3. IAM - nguoi dung (can School va Citizen nen tao sau)
   ===================================================================== */
CREATE TABLE iam.AppUser (
    UserId       bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_AppUser PRIMARY KEY,
    Email        nvarchar(256) NOT NULL CONSTRAINT UQ_AppUser_Email UNIQUE,
    DisplayName  nvarchar(200) NOT NULL,
    PasswordHash nvarchar(200) NULL,        -- HQ/School dang nhap local; Parent qua SingPass mock thi de NULL
    RoleId       tinyint       NOT NULL CONSTRAINT FK_AppUser_Role    REFERENCES iam.AppRole(RoleId),
    SchoolId     int           NULL     CONSTRAINT FK_AppUser_School  REFERENCES edu.School(SchoolId),      -- chi dung cho School user
    CitizenId    bigint        NULL     CONSTRAINT FK_AppUser_Citizen REFERENCES edu.Citizen(CitizenId),    -- chi dung cho Parent
    CanSimulate  bit           NOT NULL CONSTRAINT DF_AppUser_CanSimulate DEFAULT 0,                        -- quyen rieng cho Simulate
    IsActive     bit           NOT NULL CONSTRAINT DF_AppUser_IsActive    DEFAULT 1,
    CreatedAt    datetime2(0)  NOT NULL CONSTRAINT DF_AppUser_CreatedAt   DEFAULT SYSUTCDATETIME(),
    LastLoginAt  datetime2(0)  NULL
);

-- Hoc sinh = cong dan dang hoc (hoac da tung hoc) o truong MOE. Truong va lop xem trong StudentEnrolment.
CREATE TABLE edu.Student (
    StudentId  bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Student PRIMARY KEY,
    CitizenId  bigint       NOT NULL CONSTRAINT UQ_Student_Citizen UNIQUE
                                     CONSTRAINT FK_Student_Citizen REFERENCES edu.Citizen(CitizenId),
    CreatedAt  datetime2(0) NOT NULL CONSTRAINT DF_Student_CreatedAt DEFAULT SYSUTCDATETIME()
);

-- Lich su nhap hoc: moi dong la mot lop trong mot khoang thoi gian. Chuyen truong = dong cu, mo dong moi.
CREATE TABLE edu.StudentEnrolment (
    EnrolmentId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_StudentEnrolment PRIMARY KEY,
    StudentId   bigint      NOT NULL CONSTRAINT FK_Enrolment_Student REFERENCES edu.Student(StudentId),
    ClassId     int         NOT NULL CONSTRAINT FK_Enrolment_Class   REFERENCES edu.Class(ClassId),
    StartDate   date        NOT NULL,
    EndDate     date        NULL,                  -- NULL = dang hoc
    Status      varchar(12) NOT NULL CONSTRAINT CK_Enrolment_Status
                            CHECK (Status IN ('ENROLLED','TRANSFERRED','GRADUATED','WITHDRAWN')),
    CONSTRAINT CK_Enrolment_Dates CHECK (EndDate IS NULL OR EndDate >= StartDate)
);
-- Moi hoc sinh chi co 1 dong dang hieu luc
CREATE UNIQUE INDEX UX_Enrolment_Open ON edu.StudentEnrolment (StudentId) WHERE EndDate IS NULL;

-- Phu huynh - hoc sinh (phai duoc xac minh moi duoc nop don / thanh toan)
CREATE TABLE edu.Guardianship (
    GuardianCitizenId bigint      NOT NULL CONSTRAINT FK_Guardianship_Citizen REFERENCES edu.Citizen(CitizenId),
    StudentId         bigint      NOT NULL CONSTRAINT FK_Guardianship_Student REFERENCES edu.Student(StudentId),
    Relationship      varchar(15) NOT NULL CONSTRAINT CK_Guardianship_Rel CHECK (Relationship IN ('FATHER','MOTHER','GUARDIAN')),
    IsVerified        bit         NOT NULL CONSTRAINT DF_Guardianship_Verified DEFAULT 0,
    VerifiedAt        datetime2(0) NULL,
    CONSTRAINT PK_Guardianship PRIMARY KEY (GuardianCitizenId, StudentId)
);

-- Ho gia dinh: don FAS nop theo ho (yeu cau #10)
CREATE TABLE edu.Household (
    HouseholdId   bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Household PRIMARY KEY,
    HouseholdNo   varchar(20) NOT NULL CONSTRAINT UQ_Household_No UNIQUE,
    HeadCitizenId bigint      NULL CONSTRAINT FK_Household_Head REFERENCES edu.Citizen(CitizenId),
    CreatedAt     datetime2(0) NOT NULL CONSTRAINT DF_Household_CreatedAt DEFAULT SYSUTCDATETIME()
);

CREATE TABLE edu.HouseholdMember (
    HouseholdId  bigint NOT NULL CONSTRAINT FK_HHMember_Household REFERENCES edu.Household(HouseholdId),
    CitizenId    bigint NOT NULL CONSTRAINT FK_HHMember_Citizen   REFERENCES edu.Citizen(CitizenId),
    Relationship varchar(30) NULL,
    CONSTRAINT PK_HouseholdMember PRIMARY KEY (HouseholdId, CitizenId)
);

/* =====================================================================
   4. FIN - quy, tai khoan giao duc, giao dich, CPF, top-up
   ===================================================================== */
-- Quy cua chinh phu cap tien cho top-up (khong phai tien cua phu huynh)
CREATE TABLE fin.Fund (
    FundId   smallint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Fund PRIMARY KEY,
    Code     varchar(30)   NOT NULL CONSTRAINT UQ_Fund_Code UNIQUE,            -- EDU_ACCOUNT_FUND
    Name     nvarchar(100) NOT NULL,
    Balance  decimal(18,2) NOT NULL CONSTRAINT DF_Fund_Balance DEFAULT 0 CONSTRAINT CK_Fund_Balance CHECK (Balance >= 0),
    RowVer   rowversion    NOT NULL
);

-- Tai khoan giao duc gan voi cong dan (tre 7-16 tuoi), ke ca tre khong hoc truong MOE
CREATE TABLE fin.EducationAccount (
    AccountId       bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_EducationAccount PRIMARY KEY,
    CitizenId       bigint        NOT NULL CONSTRAINT UQ_EduAccount_Citizen UNIQUE
                                           CONSTRAINT FK_EduAccount_Citizen REFERENCES edu.Citizen(CitizenId),
    Status          varchar(10)   NOT NULL CONSTRAINT CK_EduAccount_Status CHECK (Status IN ('ACTIVE','CLOSING','CLOSED')),
    Balance         decimal(18,2) NOT NULL CONSTRAINT DF_EduAccount_Balance DEFAULT 0   -- so du dau luon la 0
                                           CONSTRAINT CK_EduAccount_Balance CHECK (Balance >= 0),
    OpenedAt        datetime2(0)  NOT NULL CONSTRAINT DF_EduAccount_OpenedAt DEFAULT SYSUTCDATETIME(),
    ClosedAt        datetime2(0)  NULL,
    ClosureReason   varchar(20)   NULL CONSTRAINT CK_EduAccount_Closure CHECK (ClosureReason IN ('AGE_16','CITIZENSHIP_LOST','MANUAL')),
    RowVer          rowversion    NOT NULL   -- chong ghi de dong thoi khi tru/cong so du
);

-- So cai: chi them, khong sua. Amount co dau (+ nap, - tru).
CREATE TABLE fin.AccountTransaction (
    TransactionId   bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_AccountTransaction PRIMARY KEY,
    AccountId       bigint        NOT NULL CONSTRAINT FK_AccTxn_Account REFERENCES fin.EducationAccount(AccountId),
    TxnType         varchar(20)   NOT NULL CONSTRAINT CK_AccTxn_Type
                                  CHECK (TxnType IN ('TOPUP','FEE_PAYMENT','REFUND','CPF_TRANSFER','ADJUSTMENT')),
    Amount          decimal(18,2) NOT NULL,
    BalanceAfter    decimal(18,2) NOT NULL,
    ReferenceType   varchar(30)   NULL,
    ReferenceId     bigint        NULL,
    Description     nvarchar(300) NULL,
    IdempotencyKey  varchar(100)  NULL,
    CreatedByUserId bigint        NULL CONSTRAINT FK_AccTxn_User REFERENCES iam.AppUser(UserId),
    CreatedAt       datetime2(0)  NOT NULL CONSTRAINT DF_AccTxn_CreatedAt DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_AccTxn_Account_Date ON fin.AccountTransaction (AccountId, CreatedAt DESC);
CREATE UNIQUE INDEX UX_AccTxn_Idempotency ON fin.AccountTransaction (IdempotencyKey) WHERE IdempotencyKey IS NOT NULL;

-- Tai khoan CPF cua tre (MOCK). Khi tai khoan giao duc dong, so du chuyen vao day.
CREATE TABLE fin.CpfAccount (
    CpfAccountId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_CpfAccount PRIMARY KEY,
    CitizenId    bigint       NOT NULL CONSTRAINT UQ_CpfAccount_Citizen UNIQUE
                                       CONSTRAINT FK_CpfAccount_Citizen REFERENCES edu.Citizen(CitizenId),
    CpfAccountNo varchar(20)  NOT NULL CONSTRAINT UQ_CpfAccount_No UNIQUE,      -- so tai khoan gia
    CreatedAt    datetime2(0) NOT NULL CONSTRAINT DF_CpfAccount_CreatedAt DEFAULT SYSUTCDATETIME()
);

-- Moi lan chuyen so du sang CPF (goi API mock, co the loi va phai thu lai)
CREATE TABLE fin.CpfTransfer (
    TransferId    bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_CpfTransfer PRIMARY KEY,
    AccountId     bigint        NOT NULL CONSTRAINT FK_CpfTransfer_Account REFERENCES fin.EducationAccount(AccountId),
    CpfAccountId  bigint        NOT NULL CONSTRAINT FK_CpfTransfer_Cpf     REFERENCES fin.CpfAccount(CpfAccountId),
    Amount        decimal(18,2) NOT NULL CONSTRAINT CK_CpfTransfer_Amount CHECK (Amount > 0),
    Status        varchar(10)   NOT NULL CONSTRAINT CK_CpfTransfer_Status CHECK (Status IN ('PENDING','SUCCESS','FAILED')),
    ExternalRef   varchar(100)  NULL,                -- ma tham chieu tu API CPF mock
    ErrorMessage  nvarchar(400) NULL,
    TransactionId bigint        NULL CONSTRAINT FK_CpfTransfer_Txn REFERENCES fin.AccountTransaction(TransactionId),
    RequestedAt   datetime2(0)  NOT NULL CONSTRAINT DF_CpfTransfer_Requested DEFAULT SYSUTCDATETIME(),
    CompletedAt   datetime2(0)  NULL
);

-- Rule top-up cau hinh duoc: so tien co dinh, tran so du (BalanceCap), dieu kien so du, tu dong sau khi mo tai khoan
CREATE TABLE fin.TopUpRule (
    RuleId              int IDENTITY(1,1) NOT NULL CONSTRAINT PK_TopUpRule PRIMARY KEY,
    Name                nvarchar(150) NOT NULL,
    TriggerType         varchar(16)   NOT NULL CONSTRAINT CK_TopUpRule_Trigger
                                      CHECK (TriggerType IN ('MANUAL','SCHEDULED','ON_ACCOUNT_OPEN')),
    Amount              decimal(18,2) NOT NULL CONSTRAINT CK_TopUpRule_Amount CHECK (Amount > 0),
    MinAge              tinyint       NULL,
    MaxAge              tinyint       NULL,
    RequireEnrolled     bit           NOT NULL CONSTRAINT DF_TopUpRule_Enrolled DEFAULT 1,
    UseBalanceCondition bit           NOT NULL CONSTRAINT DF_TopUpRule_UseBal   DEFAULT 0,
    BalanceBelow        decimal(18,2) NULL,                  -- chi nap khi so du duoi muc nay
    BalanceCap          decimal(18,2) NULL CONSTRAINT CK_TopUpRule_Cap CHECK (BalanceCap > 0),   -- tai khoan chua toi da muc nay
    RequireApproval     bit           NOT NULL CONSTRAINT DF_TopUpRule_Approval DEFAULT 0,        -- bat/tat duyet lo top-up
    EffectiveFrom       date          NOT NULL,
    EffectiveTo         date          NULL,
    IsActive            bit           NOT NULL CONSTRAINT DF_TopUpRule_Active DEFAULT 1,
    CreatedByUserId     bigint        NOT NULL CONSTRAINT FK_TopUpRule_User REFERENCES iam.AppUser(UserId),
    CreatedAt           datetime2(0)  NOT NULL CONSTRAINT DF_TopUpRule_CreatedAt DEFAULT SYSUTCDATETIME()
);

CREATE TABLE fin.TopUpSchedule (
    ScheduleId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_TopUpSchedule PRIMARY KEY,
    RuleId     int          NOT NULL CONSTRAINT FK_TopUpSchedule_Rule REFERENCES fin.TopUpRule(RuleId),
    Frequency  varchar(10)  NOT NULL CONSTRAINT CK_TopUpSchedule_Freq CHECK (Frequency IN ('ONCE','MONTHLY','QUARTERLY','YEARLY')),
    NextRunAt  datetime2(0) NOT NULL,
    LastRunAt  datetime2(0) NULL,
    IsActive   bit          NOT NULL CONSTRAINT DF_TopUpSchedule_Active DEFAULT 1
);

CREATE TABLE fin.TopUpBatch (
    BatchId           bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_TopUpBatch PRIMARY KEY,
    RuleId            int          NULL CONSTRAINT FK_TopUpBatch_Rule     REFERENCES fin.TopUpRule(RuleId),
    ScheduleId        int          NULL CONSTRAINT FK_TopUpBatch_Schedule REFERENCES fin.TopUpSchedule(ScheduleId),
    FundId            smallint     NOT NULL CONSTRAINT FK_TopUpBatch_Fund REFERENCES fin.Fund(FundId),   -- quy chi tien
    BatchType         varchar(5)   NOT NULL CONSTRAINT CK_TopUpBatch_Type   CHECK (BatchType IN ('BATCH','ADHOC')),
    Status            varchar(16)  NOT NULL CONSTRAINT CK_TopUpBatch_Status
                                   CHECK (Status IN ('PENDING_APPROVAL','REJECTED','QUEUED','RUNNING','COMPLETED','PARTIAL','FAILED')),
    TotalCount        int          NOT NULL CONSTRAINT DF_TopUpBatch_Total   DEFAULT 0,
    SuccessCount      int          NOT NULL CONSTRAINT DF_TopUpBatch_Success DEFAULT 0,
    FailedCount       int          NOT NULL CONSTRAINT DF_TopUpBatch_Failed  DEFAULT 0,
    TotalAmount       decimal(18,2) NOT NULL CONSTRAINT DF_TopUpBatch_Amount DEFAULT 0,
    IdempotencyKey    varchar(100) NOT NULL CONSTRAINT UQ_TopUpBatch_Idem UNIQUE,   -- chong chay trung lo
    RequestedByUserId bigint       NOT NULL CONSTRAINT FK_TopUpBatch_User     REFERENCES iam.AppUser(UserId),
    ApprovedByUserId  bigint       NULL     CONSTRAINT FK_TopUpBatch_Approver REFERENCES iam.AppUser(UserId),
    ApprovedAt        datetime2(0) NULL,
    CreatedAt         datetime2(0) NOT NULL CONSTRAINT DF_TopUpBatch_CreatedAt DEFAULT SYSUTCDATETIME(),
    StartedAt         datetime2(0) NULL,
    CompletedAt       datetime2(0) NULL
);

-- Moi dong = 1 tai khoan trong lo; loi 1 dong khong lam hong ca lo (doi soat tai day)
CREATE TABLE fin.TopUpItem (
    ItemId        bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_TopUpItem PRIMARY KEY,
    BatchId       bigint        NOT NULL CONSTRAINT FK_TopUpItem_Batch   REFERENCES fin.TopUpBatch(BatchId),
    AccountId     bigint        NOT NULL CONSTRAINT FK_TopUpItem_Account REFERENCES fin.EducationAccount(AccountId),
    Amount        decimal(18,2) NOT NULL,
    Status        varchar(10)   NOT NULL CONSTRAINT CK_TopUpItem_Status CHECK (Status IN ('PENDING','SUCCESS','FAILED','SKIPPED')),
    ErrorMessage  nvarchar(400) NULL,
    TransactionId bigint        NULL CONSTRAINT FK_TopUpItem_Txn REFERENCES fin.AccountTransaction(TransactionId),
    CONSTRAINT UQ_TopUpItem UNIQUE (BatchId, AccountId)
);

/* =====================================================================
   5. FIN - hoc phi va thanh toan
   ===================================================================== */
-- Danh muc loai phi (fee type): hoc phi, phi khac, sach, dong phuc...
CREATE TABLE fin.FeeType (
    FeeTypeId smallint IDENTITY(1,1) NOT NULL CONSTRAINT PK_FeeType PRIMARY KEY,
    Code      varchar(30)   NOT NULL CONSTRAINT UQ_FeeType_Code UNIQUE,
    Name      nvarchar(100) NOT NULL,
    IsActive  bit           NOT NULL CONSTRAINT DF_FeeType_Active DEFAULT 1
);

-- Loai phi nao tra duoc bang tai khoan giao duc: cau hinh theo thoi gian vi chinh sach co the doi
CREATE TABLE fin.FeeTypePayableRule (
    PayableRuleId        int IDENTITY(1,1) NOT NULL CONSTRAINT PK_FeeTypePayableRule PRIMARY KEY,
    FeeTypeId            smallint NOT NULL CONSTRAINT FK_PayableRule_FeeType REFERENCES fin.FeeType(FeeTypeId),
    PayableByEduAccount  bit      NOT NULL,
    EffectiveFrom        date     NOT NULL,
    EffectiveTo          date     NULL,
    CreatedByUserId      bigint   NOT NULL CONSTRAINT FK_PayableRule_User REFERENCES iam.AppUser(UserId)
);

-- Khoan phi cua tung lop (truong, cap hoc, nam hoc suy ra tu Class)
CREATE TABLE fin.FeeComponent (
    FeeComponentId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_FeeComponent PRIMARY KEY,
    ClassId        int           NOT NULL CONSTRAINT FK_FeeComponent_Class REFERENCES edu.Class(ClassId),
    FeeTypeId      smallint      NOT NULL CONSTRAINT FK_FeeComponent_Type  REFERENCES fin.FeeType(FeeTypeId),
    Term           tinyint       NULL,
    Amount         decimal(18,2) NOT NULL CONSTRAINT CK_FeeComponent_Amount CHECK (Amount >= 0),
    DueDate        date          NOT NULL,
    CONSTRAINT UQ_FeeComponent UNIQUE (ClassId, FeeTypeId, Term)
);

-- Khoan phai dong cua tung hoc sinh. Tro cap FAS tru vao SubsidyAmount.
CREATE TABLE fin.StudentCharge (
    ChargeId       bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_StudentCharge PRIMARY KEY,
    StudentId      bigint        NOT NULL CONSTRAINT FK_Charge_Student   REFERENCES edu.Student(StudentId),
    FeeComponentId int           NOT NULL CONSTRAINT FK_Charge_Component REFERENCES fin.FeeComponent(FeeComponentId),
    AmountDue      decimal(18,2) NOT NULL,
    SubsidyAmount  decimal(18,2) NOT NULL CONSTRAINT DF_Charge_Subsidy DEFAULT 0,
    AmountPaid     decimal(18,2) NOT NULL CONSTRAINT DF_Charge_Paid    DEFAULT 0,
    NetPayable     AS (AmountDue - SubsidyAmount) PERSISTED,
    Outstanding    AS (AmountDue - SubsidyAmount - AmountPaid) PERSISTED,
    Status         varchar(10)   NOT NULL CONSTRAINT CK_Charge_Status
                                 CHECK (Status IN ('UNPAID','PARTIAL','PAID','WAIVED','OVERDUE','BAD_DEBT')),   -- BAD_DEBT: no con lai khi dong tai khoan
    DueDate        date          NOT NULL,
    CreatedAt      datetime2(0)  NOT NULL CONSTRAINT DF_Charge_CreatedAt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_Charge UNIQUE (StudentId, FeeComponentId)
);
CREATE INDEX IX_Charge_Student_Status ON fin.StudentCharge (StudentId, Status);

CREATE TABLE fin.Payment (
    PaymentId      bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Payment PRIMARY KEY,
    ChargeId       bigint        NOT NULL CONSTRAINT FK_Payment_Charge REFERENCES fin.StudentCharge(ChargeId),
    PayerUserId    bigint        NOT NULL CONSTRAINT FK_Payment_Payer  REFERENCES iam.AppUser(UserId),
    Method         varchar(12)   NOT NULL CONSTRAINT CK_Payment_Method CHECK (Method IN ('EDU_BALANCE','ONLINE')),
    Channel        varchar(10)   NULL     CONSTRAINT CK_Payment_Channel CHECK (Channel IN ('CARD','PAYNOW','NETS')),   -- chi cho ONLINE
    Amount         decimal(18,2) NOT NULL CONSTRAINT CK_Payment_Amount CHECK (Amount > 0),
    Status         varchar(10)   NOT NULL CONSTRAINT CK_Payment_Status CHECK (Status IN ('PENDING','SUCCESS','FAILED')),
    GatewayRef     varchar(100)  NULL,                -- ma tu cong thanh toan mock
    IdempotencyKey varchar(100)  NULL,                -- chong bam dup nut thanh toan
    TransactionId  bigint        NULL CONSTRAINT FK_Payment_Txn REFERENCES fin.AccountTransaction(TransactionId),
    CreatedAt      datetime2(0)  NOT NULL CONSTRAINT DF_Payment_CreatedAt DEFAULT SYSUTCDATETIME(),
    CompletedAt    datetime2(0)  NULL,
    CONSTRAINT CK_Payment_MethodChannel CHECK ((Method = 'ONLINE' AND Channel IS NOT NULL) OR (Method = 'EDU_BALANCE' AND Channel IS NULL))
);
CREATE UNIQUE INDEX UX_Payment_Idempotency ON fin.Payment (IdempotencyKey) WHERE IdempotencyKey IS NOT NULL;

/* =====================================================================
   6. FAS - chinh sach, khoang thu nhap, tier, don gia dinh, ket qua tung con
   ===================================================================== */
CREATE TABLE fas.Scheme (
    SchemeId tinyint       NOT NULL CONSTRAINT PK_Scheme PRIMARY KEY,
    Code     varchar(20)   NOT NULL CONSTRAINT UQ_Scheme_Code UNIQUE,      -- MOEFAS, SBFAS
    Name     nvarchar(150) NOT NULL,
    Scope    varchar(10)   NOT NULL CONSTRAINT CK_Scheme_Scope CHECK (Scope IN ('NATIONAL','SCHOOL'))
);

-- Moi lan doi chinh sach tao phien ban moi; ket qua luon gan voi phien ban da ap dung
CREATE TABLE fas.PolicyVersion (
    PolicyVersionId     int IDENTITY(1,1) NOT NULL CONSTRAINT PK_PolicyVersion PRIMARY KEY,
    SchemeId            tinyint     NOT NULL CONSTRAINT FK_PolicyVersion_Scheme REFERENCES fas.Scheme(SchemeId),
    SchoolId            int         NULL     CONSTRAINT FK_PolicyVersion_School REFERENCES edu.School(SchoolId),   -- NULL = quoc gia
    VersionNo           int         NOT NULL,
    RequiredNationality varchar(20) NULL,
    RequireEnrolled     bit         NOT NULL CONSTRAINT DF_PolicyVersion_Enrolled DEFAULT 1,
    EffectiveFrom       date        NOT NULL,
    EffectiveTo         date        NULL,
    Status              varchar(10) NOT NULL CONSTRAINT CK_PolicyVersion_Status CHECK (Status IN ('DRAFT','ACTIVE','RETIRED')),
    CreatedByUserId     bigint      NOT NULL CONSTRAINT FK_PolicyVersion_User REFERENCES iam.AppUser(UserId),
    CreatedAt           datetime2(0) NOT NULL CONSTRAINT DF_PolicyVersion_CreatedAt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_PolicyVersion UNIQUE (SchemeId, SchoolId, VersionNo)
);

-- Khoang thu nhap tu he thong ben thu ba (chi tra khoang, khong tra so chinh xac)
CREATE TABLE fas.IncomeBand (
    IncomeBandId smallint IDENTITY(1,1) NOT NULL CONSTRAINT PK_IncomeBand PRIMARY KEY,
    BandType     varchar(10)   NOT NULL CONSTRAINT CK_IncomeBand_Type CHECK (BandType IN ('HOUSEHOLD','PER_CAPITA')),
    Code         varchar(10)   NOT NULL,
    Name         nvarchar(60)  NOT NULL,
    MinAmount    decimal(18,2) NULL,
    MaxAmount    decimal(18,2) NULL,
    SortOrder    tinyint       NOT NULL,         -- so sanh khoang bang SortOrder
    CONSTRAINT UQ_IncomeBand UNIQUE (BandType, Code)
);

-- Tier xac dinh theo khoang thu nhap (khoang cao nhat con duoc tier nay)
CREATE TABLE fas.BenefitTier (
    TierId             int IDENTITY(1,1) NOT NULL CONSTRAINT PK_BenefitTier PRIMARY KEY,
    PolicyVersionId    int           NOT NULL CONSTRAINT FK_Tier_Policy REFERENCES fas.PolicyVersion(PolicyVersionId),
    TierNo             tinyint       NOT NULL,
    Name               nvarchar(50)  NOT NULL,
    MaxPerCapitaBandId smallint      NULL CONSTRAINT FK_Tier_PerCapitaBand REFERENCES fas.IncomeBand(IncomeBandId),
    MaxHouseholdBandId smallint      NULL CONSTRAINT FK_Tier_HouseholdBand REFERENCES fas.IncomeBand(IncomeBandId),
    CONSTRAINT UQ_Tier UNIQUE (PolicyVersionId, TierNo)
);

-- So tien co dinh cua tung tier theo tung loai phi
CREATE TABLE fas.TierBenefit (
    TierId    int           NOT NULL CONSTRAINT FK_TierBenefit_Tier REFERENCES fas.BenefitTier(TierId),
    FeeTypeId smallint      NOT NULL CONSTRAINT FK_TierBenefit_Fee  REFERENCES fin.FeeType(FeeTypeId),
    Amount    decimal(18,2) NOT NULL,
    Frequency varchar(5)    NOT NULL CONSTRAINT CK_TierBenefit_Freq CHECK (Frequency IN ('TERM','YEAR','ONCE')),
    CONSTRAINT PK_TierBenefit PRIMARY KEY (TierId, FeeTypeId)
);

-- Ban chup ket qua tra cuu thu nhap ho (tra cuu theo NRIC, tra khoang va so thanh vien)
CREATE TABLE fas.HouseholdIncomeSnapshot (
    SnapshotId       bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_IncomeSnapshot PRIMARY KEY,
    HouseholdId      bigint       NOT NULL CONSTRAINT FK_Income_Household REFERENCES edu.Household(HouseholdId),
    HouseholdBandId  smallint     NOT NULL CONSTRAINT FK_Income_HouseholdBand REFERENCES fas.IncomeBand(IncomeBandId),
    PerCapitaBandId  smallint     NOT NULL CONSTRAINT FK_Income_PerCapitaBand REFERENCES fas.IncomeBand(IncomeBandId),
    MemberCount      tinyint      NOT NULL,
    Source           varchar(20)  NOT NULL CONSTRAINT DF_Income_Source DEFAULT 'INCOME_API_MOCK',
    FetchedAt        datetime2(0) NOT NULL CONSTRAINT DF_Income_FetchedAt DEFAULT SYSUTCDATETIME()
);

-- Don xin tro cap: 1 don cho ca ho (yeu cau #10)
CREATE TABLE fas.Application (
    ApplicationId     bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Application PRIMARY KEY,
    HouseholdId       bigint      NOT NULL CONSTRAINT FK_Application_Household REFERENCES edu.Household(HouseholdId),
    AcademicYear      smallint    NOT NULL,
    Channel           varchar(6)  NOT NULL CONSTRAINT CK_Application_Channel CHECK (Channel IN ('ONLINE','PAPER')),
    SubmittedByUserId bigint      NULL CONSTRAINT FK_Application_Parent  REFERENCES iam.AppUser(UserId),
    EnteredByUserId   bigint      NULL CONSTRAINT FK_Application_Staff   REFERENCES iam.AppUser(UserId),   -- nhan vien truong nhap thay (don giay)
    IncomeSnapshotId  bigint      NULL CONSTRAINT FK_Application_Income  REFERENCES fas.HouseholdIncomeSnapshot(SnapshotId),
    Status            varchar(10) NOT NULL CONSTRAINT CK_Application_Status
                                  CHECK (Status IN ('DRAFT','SUBMITTED','IN_REVIEW','COMPLETED','CANCELLED')),
    CreatedAt         datetime2(0) NOT NULL CONSTRAINT DF_Application_CreatedAt DEFAULT SYSUTCDATETIME(),
    SubmittedAt       datetime2(0) NULL,
    RowVer            rowversion  NOT NULL
);
-- Chong nop trung: moi ho chi co 1 don dang hieu luc cho moi nam hoc
CREATE UNIQUE INDEX UX_Application_Active ON fas.Application (HouseholdId, AcademicYear) WHERE Status <> 'CANCELLED';

CREATE TABLE fas.ApplicationChild (
    ApplicationChildId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ApplicationChild PRIMARY KEY,
    ApplicationId      bigint NOT NULL CONSTRAINT FK_AppChild_Application REFERENCES fas.Application(ApplicationId),
    StudentId          bigint NOT NULL CONSTRAINT FK_AppChild_Student     REFERENCES edu.Student(StudentId),
    CONSTRAINT UQ_AppChild UNIQUE (ApplicationId, StudentId)
);

-- Ket qua rieng cho tung con theo tung chuong trinh. DecidedByUserId = NULL nghia la rule engine tu quyet.
CREATE TABLE fas.ChildResult (
    ResultId           bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ChildResult PRIMARY KEY,
    ApplicationChildId bigint        NOT NULL CONSTRAINT FK_Result_AppChild REFERENCES fas.ApplicationChild(ApplicationChildId),
    SchemeId           tinyint       NOT NULL CONSTRAINT FK_Result_Scheme   REFERENCES fas.Scheme(SchemeId),
    PolicyVersionId    int           NOT NULL CONSTRAINT FK_Result_Policy   REFERENCES fas.PolicyVersion(PolicyVersionId),
    TierId             int           NULL     CONSTRAINT FK_Result_Tier     REFERENCES fas.BenefitTier(TierId),
    Status             varchar(15)   NOT NULL CONSTRAINT CK_Result_Status
                                     CHECK (Status IN ('NOT_ELIGIBLE','GRANTED','PENDING_SBFAS','APPROVED','DECLINED')),
    TotalAmount        decimal(18,2) NOT NULL CONSTRAINT DF_Result_Amount DEFAULT 0,
    Reason             nvarchar(400) NULL,
    DecidedAt          datetime2(0)  NULL,
    DecidedByUserId    bigint        NULL CONSTRAINT FK_Result_Decider REFERENCES iam.AppUser(UserId),
    CONSTRAINT UQ_Result UNIQUE (ApplicationChildId, SchemeId)
);
-- Mot con chi huong 1 chuong trinh: MOE FAS hoac SBFAS, khong ca hai
CREATE UNIQUE INDEX UX_Result_OneGrant ON fas.ChildResult (ApplicationChildId) WHERE Status IN ('GRANTED','APPROVED');

-- Tro cap duoc phan bo vao tung khoan phi cu the
CREATE TABLE fin.ChargeSubsidy (
    ChargeSubsidyId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ChargeSubsidy PRIMARY KEY,
    ChargeId        bigint        NOT NULL CONSTRAINT FK_ChargeSubsidy_Charge REFERENCES fin.StudentCharge(ChargeId),
    ResultId        bigint        NOT NULL CONSTRAINT FK_ChargeSubsidy_Result REFERENCES fas.ChildResult(ResultId),
    Amount          decimal(18,2) NOT NULL CONSTRAINT CK_ChargeSubsidy_Amount CHECK (Amount > 0)
);

-- Quy trinh duyet SBFAS cua tung truong (so buoc cau hinh duoc, mac dinh 1 buoc)
CREATE TABLE fas.SbfasWorkflowStep (
    WorkflowStepId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SbfasWorkflowStep PRIMARY KEY,
    SchoolId       int           NOT NULL CONSTRAINT FK_SbfasWf_School REFERENCES edu.School(SchoolId),
    StepNo         tinyint       NOT NULL,
    Name           nvarchar(100) NOT NULL,
    ReviewerRoleId tinyint       NOT NULL CONSTRAINT FK_SbfasWf_Role REFERENCES iam.AppRole(RoleId),
    CONSTRAINT UQ_SbfasWf UNIQUE (SchoolId, StepNo)
);

CREATE TABLE fas.SbfasReviewStep (
    ReviewStepId   bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_SbfasReviewStep PRIMARY KEY,
    ResultId       bigint        NOT NULL CONSTRAINT FK_SbfasReview_Result   REFERENCES fas.ChildResult(ResultId),
    StepNo         tinyint       NOT NULL,
    StepName       nvarchar(100) NOT NULL,
    ReviewerUserId bigint        NULL CONSTRAINT FK_SbfasReview_Reviewer REFERENCES iam.AppUser(UserId),
    Decision       varchar(10)   NOT NULL CONSTRAINT CK_SbfasReview_Decision
                                 CHECK (Decision IN ('PENDING','APPROVED','REJECTED','RETURNED')),
    Comment        nvarchar(500) NULL,
    DecidedAt      datetime2(0)  NULL,
    CONSTRAINT UQ_SbfasReview UNIQUE (ResultId, StepNo)
);

-- Ngan sach: MOE FAS (SchoolId = NULL) do HQ dat, SBFAS do tung truong dat. Chi gioi han tong, khong gioi han theo dau nguoi.
CREATE TABLE fas.Budget (
    BudgetId        int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Budget PRIMARY KEY,
    SchemeId        tinyint       NOT NULL CONSTRAINT FK_Budget_Scheme REFERENCES fas.Scheme(SchemeId),
    SchoolId        int           NULL     CONSTRAINT FK_Budget_School REFERENCES edu.School(SchoolId),
    AcademicYear    smallint      NOT NULL,
    TotalBudget     decimal(18,2) NOT NULL CONSTRAINT CK_Budget_Total CHECK (TotalBudget >= 0),
    UsedAmount      decimal(18,2) NOT NULL CONSTRAINT DF_Budget_Used  DEFAULT 0,
    CreatedByUserId bigint        NOT NULL CONSTRAINT FK_Budget_User REFERENCES iam.AppUser(UserId),
    CONSTRAINT UQ_Budget UNIQUE (SchemeId, SchoolId, AcademicYear)
);

-- Tung truong cua form: AI goi y vs gia tri cuoi. Source cho biet gia tri den tu dau.
CREATE TABLE fas.ApplicationFieldValue (
    FieldValueId     bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_AppFieldValue PRIMARY KEY,
    ApplicationId    bigint        NOT NULL CONSTRAINT FK_FieldValue_Application REFERENCES fas.Application(ApplicationId),
    FieldKey         varchar(60)   NOT NULL,
    AiSuggestedValue nvarchar(500) NULL,
    FinalValue       nvarchar(500) NULL,
    Source           varchar(15)   NOT NULL CONSTRAINT CK_FieldValue_Source
                                   CHECK (Source IN ('PROFILE','INCOME_API','CHAT','USER','SCHOOL_STAFF')),
    IsLocked         bit           NOT NULL CONSTRAINT DF_FieldValue_Locked DEFAULT 0,
    UpdatedAt        datetime2(0)  NOT NULL CONSTRAINT DF_FieldValue_UpdatedAt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_FieldValue UNIQUE (ApplicationId, FieldKey)
);

-- ML chi de tham khao cho nhan vien (MOE FAS dung rule quyet tier; SBFAS dung de goi y so tien)
CREATE TABLE fas.RiskAssessment (
    RiskId          bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_RiskAssessment PRIMARY KEY,
    ApplicationId   bigint        NOT NULL CONSTRAINT FK_Risk_Application REFERENCES fas.Application(ApplicationId),
    RiskLevel       varchar(6)    NOT NULL CONSTRAINT CK_Risk_Level CHECK (RiskLevel IN ('LOW','MEDIUM','HIGH')),
    Probability     decimal(5,4)  NOT NULL CONSTRAINT CK_Risk_Prob  CHECK (Probability BETWEEN 0 AND 1),
    SuggestedAmount decimal(18,2) NULL,
    ModelVersion    varchar(30)   NOT NULL,
    CreatedAt       datetime2(0)  NOT NULL CONSTRAINT DF_Risk_CreatedAt DEFAULT SYSUTCDATETIME()
);

-- Don giay: file quet luu o Blob storage, OCR la tuy chon
CREATE TABLE fas.PaperScan (
    ScanId           bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_PaperScan PRIMARY KEY,
    ApplicationId    bigint        NOT NULL CONSTRAINT FK_Scan_Application REFERENCES fas.Application(ApplicationId),
    BlobUri          nvarchar(500) NOT NULL,
    OcrStatus        varchar(10)   NOT NULL CONSTRAINT DF_Scan_Ocr DEFAULT 'NONE'
                                   CONSTRAINT CK_Scan_Ocr CHECK (OcrStatus IN ('NONE','PENDING','DONE','FAILED')),
    DetectedSchemeId tinyint       NULL CONSTRAINT FK_Scan_Scheme REFERENCES fas.Scheme(SchemeId),
    OcrConfidence    decimal(5,4)  NULL,
    UploadedByUserId bigint        NOT NULL CONSTRAINT FK_Scan_User REFERENCES iam.AppUser(UserId),
    UploadedAt       datetime2(0)  NOT NULL CONSTRAINT DF_Scan_UploadedAt DEFAULT SYSUTCDATETIME()
);

/* =====================================================================
   7. AI - kho tri thuc RAG va chatbot
   ===================================================================== */
CREATE TABLE ai.KnowledgeDocument (
    DocumentId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_KnowledgeDocument PRIMARY KEY,
    Title      nvarchar(200) NOT NULL,
    SourceType varchar(5)    NOT NULL CONSTRAINT CK_KDoc_Type CHECK (SourceType IN ('GUIDE','FAQ')),
    SourceUri  nvarchar(500) NULL,
    Language   varchar(5)    NOT NULL CONSTRAINT DF_KDoc_Lang DEFAULT 'en',
    Version    int           NOT NULL CONSTRAINT DF_KDoc_Version DEFAULT 1,
    IsActive   bit           NOT NULL CONSTRAINT DF_KDoc_Active DEFAULT 1,
    CreatedAt  datetime2(0)  NOT NULL CONSTRAINT DF_KDoc_CreatedAt DEFAULT SYSUTCDATETIME()
);

-- Embedding luu varbinary(max) de chay duoc moi phien ban; dung kieu VECTOR neu server ho tro
CREATE TABLE ai.KnowledgeChunk (
    ChunkId    bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_KnowledgeChunk PRIMARY KEY,
    DocumentId int            NOT NULL CONSTRAINT FK_KChunk_Doc REFERENCES ai.KnowledgeDocument(DocumentId) ON DELETE CASCADE,
    ChunkIndex int            NOT NULL,
    Content    nvarchar(max)  NOT NULL,
    TokenCount int            NULL,
    Embedding  varbinary(max) NULL,
    CONSTRAINT UQ_KChunk UNIQUE (DocumentId, ChunkIndex)
);

CREATE TABLE ai.ChatSession (
    SessionId uniqueidentifier NOT NULL CONSTRAINT PK_ChatSession PRIMARY KEY CONSTRAINT DF_ChatSession_Id DEFAULT NEWID(),
    UserId    bigint       NOT NULL CONSTRAINT FK_ChatSession_User REFERENCES iam.AppUser(UserId),
    StartedAt datetime2(0) NOT NULL CONSTRAINT DF_ChatSession_Started DEFAULT SYSUTCDATETIME(),
    EndedAt   datetime2(0) NULL
);

CREATE TABLE ai.ChatMessage (
    MessageId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ChatMessage PRIMARY KEY,
    SessionId uniqueidentifier NOT NULL CONSTRAINT FK_ChatMessage_Session REFERENCES ai.ChatSession(SessionId) ON DELETE CASCADE,
    Role      varchar(10)   NOT NULL CONSTRAINT CK_ChatMessage_Role CHECK (Role IN ('USER','ASSISTANT')),
    Content   nvarchar(max) NOT NULL,
    CreatedAt datetime2(0)  NOT NULL CONSTRAINT DF_ChatMessage_CreatedAt DEFAULT SYSUTCDATETIME()
);

-- Nguon trich dan cua moi cau tra loi
CREATE TABLE ai.MessageCitation (
    MessageId bigint        NOT NULL CONSTRAINT FK_Citation_Message REFERENCES ai.ChatMessage(MessageId) ON DELETE CASCADE,
    ChunkId   bigint        NOT NULL CONSTRAINT FK_Citation_Chunk   REFERENCES ai.KnowledgeChunk(ChunkId),
    Score     decimal(6,5)  NULL,
    CONSTRAINT PK_MessageCitation PRIMARY KEY (MessageId, ChunkId)
);

/* =====================================================================
   8. AUD - simulate, audit log, job nen
   ===================================================================== */
-- Phien xem thay chi doc cua HQ (yeu cau #7)
CREATE TABLE aud.SimulationSession (
    SimulationSessionId uniqueidentifier NOT NULL CONSTRAINT PK_SimulationSession PRIMARY KEY
                                         CONSTRAINT DF_SimSession_Id DEFAULT NEWID(),
    ActorUserId  bigint        NOT NULL CONSTRAINT FK_SimSession_Actor  REFERENCES iam.AppUser(UserId),   -- nhan vien HQ (CanSimulate = 1)
    TargetUserId bigint        NOT NULL CONSTRAINT FK_SimSession_Target REFERENCES iam.AppUser(UserId),   -- nguoi bi xem
    TargetRoleId tinyint       NOT NULL CONSTRAINT FK_SimSession_Role   REFERENCES iam.AppRole(RoleId),
    SchoolId     int           NULL     CONSTRAINT FK_SimSession_School REFERENCES edu.School(SchoolId),
    Reason       nvarchar(300) NOT NULL CONSTRAINT CK_SimSession_Reason CHECK (LEN(Reason) >= 5),
    StartedAt    datetime2(0)  NOT NULL CONSTRAINT DF_SimSession_Started DEFAULT SYSUTCDATETIME(),
    ExpiresAt    datetime2(0)  NOT NULL,
    EndedAt      datetime2(0)  NULL,
    EndReason    varchar(10)   NULL CONSTRAINT CK_SimSession_End CHECK (EndReason IN ('MANUAL','EXPIRED','LOGOUT')),
    IpAddress    varchar(45)   NULL
);

CREATE TABLE aud.AuditLog (
    AuditId             bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_AuditLog PRIMARY KEY,
    OccurredAt          datetime2(3)  NOT NULL CONSTRAINT DF_AuditLog_Occurred DEFAULT SYSUTCDATETIME(),
    ActorUserId         bigint        NULL CONSTRAINT FK_AuditLog_Actor REFERENCES iam.AppUser(UserId),          -- luon la nguoi that su thao tac (HQ khi simulate)
    SimulationSessionId uniqueidentifier NULL CONSTRAINT FK_AuditLog_Sim REFERENCES aud.SimulationSession(SimulationSessionId),
    Action              varchar(50)   NOT NULL,     -- TOPUP_BATCH_RUN, FAS_DECISION, CPF_TRANSFER, SIMULATION_STARTED, SIMULATION_WRITE_BLOCKED...
    EntityType          varchar(50)   NULL,
    EntityId            varchar(50)   NULL,
    Detail              nvarchar(max) NULL,         -- khong ghi du lieu nhay cam
    IpAddress           varchar(45)   NULL
);
CREATE INDEX IX_AuditLog_Entity ON aud.AuditLog (EntityType, EntityId);
CREATE INDEX IX_AuditLog_Actor  ON aud.AuditLog (ActorUserId, OccurredAt DESC);
GO

-- Audit log chi them, khong sua, khong xoa (rang buoc o tang database)
CREATE TRIGGER aud.TR_AuditLog_AppendOnly
ON aud.AuditLog
INSTEAD OF UPDATE, DELETE
AS
BEGIN
    THROW 50001, N'aud.AuditLog la bang chi them (append-only).', 1;
END;
GO

CREATE TABLE aud.JobRun (
    JobRunId       bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_JobRun PRIMARY KEY,
    JobName        varchar(50)   NOT NULL,       -- CITIZEN_FEED_IMPORT, ACCOUNT_LIFECYCLE, TOPUP_SCHEDULE...
    StartedAt      datetime2(0)  NOT NULL CONSTRAINT DF_JobRun_Started DEFAULT SYSUTCDATETIME(),
    FinishedAt     datetime2(0)  NULL,
    Status         varchar(10)   NOT NULL CONSTRAINT CK_JobRun_Status CHECK (Status IN ('RUNNING','SUCCESS','FAILED')),
    ProcessedCount int           NOT NULL CONSTRAINT DF_JobRun_Count DEFAULT 0,
    Message        nvarchar(500) NULL
);
GO

/* =====================================================================
   9. Du lieu tham chieu (reference data). Du lieu mock se seed sau.
   ===================================================================== */
INSERT iam.AppRole (RoleId, Code, Name) VALUES
    (1, 'MOE_HQ',          N'MOE HQ user'),
    (2, 'SCHOOL_STAFF',    N'School staff (enter data, enter paper applications, first review)'),
    (3, 'SCHOOL_APPROVER', N'School approver (final SBFAS approval)'),
    (4, 'PARENT',          N'Parent');

INSERT edu.Level (LevelId, Code, Name, Stage, SortOrder) VALUES
    (1,'P1',N'Primary 1','PRIMARY',1),(2,'P2',N'Primary 2','PRIMARY',2),(3,'P3',N'Primary 3','PRIMARY',3),
    (4,'P4',N'Primary 4','PRIMARY',4),(5,'P5',N'Primary 5','PRIMARY',5),(6,'P6',N'Primary 6','PRIMARY',6),
    (7,'S1',N'Secondary 1','SECONDARY',7),(8,'S2',N'Secondary 2','SECONDARY',8),(9,'S3',N'Secondary 3','SECONDARY',9),
    (10,'S4',N'Secondary 4','SECONDARY',10),(11,'S5',N'Secondary 5','SECONDARY',11);

INSERT fin.FeeType (Code, Name) VALUES
    ('SCHOOL_FEES', N'School fees'), ('MISC_FEES', N'Miscellaneous fees'),
    ('TEXTBOOKS',   N'Textbooks'),   ('UNIFORM',   N'School uniform');

INSERT fin.Fund (Code, Name, Balance) VALUES ('EDU_ACCOUNT_FUND', N'Education account fund (government)', 1000000);

INSERT fas.Scheme (SchemeId, Code, Name, Scope) VALUES
    (1, 'MOEFAS', N'MOE Financial Assistance Scheme', 'NATIONAL'),
    (2, 'SBFAS',  N'School-based Financial Assistance Scheme', 'SCHOOL');

-- Khoang thu nhap MAU (so lieu minh hoa, khong phai so that)
INSERT fas.IncomeBand (BandType, Code, Name, MinAmount, MaxAmount, SortOrder) VALUES
    ('HOUSEHOLD','HB1',N'Up to 3,000',     NULL, 3000, 1),
    ('HOUSEHOLD','HB2',N'3,001 - 6,000',   3001, 6000, 2),
    ('HOUSEHOLD','HB3',N'6,001 - 9,000',   6001, 9000, 3),
    ('HOUSEHOLD','HB4',N'Above 9,000',     9001, NULL, 4),
    ('PER_CAPITA','PB1',N'Up to 500',      NULL, 500,  1),
    ('PER_CAPITA','PB2',N'501 - 1,000',    501, 1000,  2),
    ('PER_CAPITA','PB3',N'1,001 - 1,500',  1001, 1500, 3),
    ('PER_CAPITA','PB4',N'Above 1,500',    1501, NULL, 4);

-- Tai khoan HQ mau + chinh sach MOE FAS mau (so lieu minh hoa theo vi du trong BR, khong phai chinh sach that)
INSERT iam.AppUser (Email, DisplayName, RoleId, CanSimulate) VALUES (N'hq.admin@edufund.mock', N'HQ Admin', 1, 1);
DECLARE @hq bigint = SCOPE_IDENTITY();

-- Mac dinh moi loai phi deu tra duoc bang tai khoan giao duc (co the doi theo chinh sach)
INSERT fin.FeeTypePayableRule (FeeTypeId, PayableByEduAccount, EffectiveFrom, CreatedByUserId)
SELECT FeeTypeId, 1, '2026-01-01', @hq FROM fin.FeeType;

INSERT fas.PolicyVersion (SchemeId, SchoolId, VersionNo, RequiredNationality, RequireEnrolled, EffectiveFrom, Status, CreatedByUserId)
VALUES (1, NULL, 1, 'SINGAPORE_CITIZEN', 1, '2026-01-01', 'ACTIVE', @hq);
DECLARE @pv int = SCOPE_IDENTITY();

INSERT fas.BenefitTier (PolicyVersionId, TierNo, Name, MaxPerCapitaBandId)
SELECT @pv, v.TierNo, v.Name, b.IncomeBandId
FROM (VALUES (1, N'Tier 1', 'PB1'), (2, N'Tier 2', 'PB2'), (3, N'Tier 3', 'PB3')) AS v(TierNo, Name, BandCode)
JOIN fas.IncomeBand b ON b.BandType = 'PER_CAPITA' AND b.Code = v.BandCode;

INSERT fas.TierBenefit (TierId, FeeTypeId, Amount, Frequency)
SELECT t.TierId, f.FeeTypeId,
       CASE t.TierNo WHEN 1 THEN 500 WHEN 2 THEN 300 ELSE 100 END, 'YEAR'
FROM fas.BenefitTier t
CROSS JOIN fin.FeeType f
WHERE t.PolicyVersionId = @pv AND f.Code = 'SCHOOL_FEES';
GO

/* =====================================================================
   10. Kiem tra: so bang theo schema, va danh sach quan he giua cac bang
   ===================================================================== */
SELECT s.name AS [schema], COUNT(*) AS [tables]
FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE s.name IN (N'iam', N'edu', N'fin', N'fas', N'ai', N'aud')
GROUP BY s.name
ORDER BY s.name;

SELECT OBJECT_SCHEMA_NAME(f.parent_object_id) + N'.' + OBJECT_NAME(f.parent_object_id)         AS child_table,
       OBJECT_SCHEMA_NAME(f.referenced_object_id) + N'.' + OBJECT_NAME(f.referenced_object_id) AS parent_table,
       f.name AS foreign_key
FROM sys.foreign_keys f
ORDER BY child_table, parent_table;
GO
